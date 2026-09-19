import AppKit
import Observation
import NoteLumeCore
import SwiftUI

/// Per-window state shared with the editor UI.
@MainActor
@Observable
final class NoteWindowState {
    var alwaysOnTop: Bool
    init(alwaysOnTop: Bool) { self.alwaysOnTop = alwaysOnTop }
}

/// Owns note windows. Notes open as ordinary windows, or as floating sticky
/// windows (translucent, optionally always on top). Window frames are device
/// specific and live in the local SQLite database, never in the note file
/// (requirements §6).
@MainActor
final class NoteWindowManager: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var windows: [UUID: NSWindow] = [:]
    private var states: [UUID: NoteWindowState] = [:]
    private var pendingOpens: Set<UUID> = []
    private var geometryTasks: [UUID: Task<Void, Never>] = [:]
    private var lastOrigin: NSPoint?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Showing

    func show(_ id: UUID) {
        if let w = windows[id] {
            if w.isMiniaturized { w.deminiaturize(nil) }
            bringToFront(w)
            return
        }
        guard pendingOpens.insert(id).inserted else { return }
        Task {
            defer { pendingOpens.remove(id) }
            do {
                let session = try await model.session(for: id)
                build(session)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    /// Re-opens sticky notes that were open on this Mac when the app last quit.
    func restoreStickyWindows() {
        guard let store = model.store else { return }
        for id in (try? store.index.openWindowNoteIDs()) ?? [] where model.summary(id)?.sticky == true {
            show(id)
        }
    }

    /// Closes a note's window without any prompts (e.g. after the note was trashed).
    func close(_ id: UUID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        w.delegate = nil
        w.close()
        states[id] = nil
    }

    func closeAll() {
        for id in Array(windows.keys) { close(id) }
    }

    func setAlwaysOnTop(_ id: UUID, _ on: Bool) {
        states[id]?.alwaysOnTop = on
        windows[id]?.level = on ? .floating : .normal
        saveGeometry(id, isOpen: true)
    }

    // MARK: Building

    private func build(_ session: NoteEditSession) {
        let id = session.noteID
        guard windows[id] == nil, let store = model.store, let settings = model.settings else { return }
        let sticky = session.document.metadata.sticky
        let saved = (try? store.index.windowGeometry(for: id)) ?? nil
        let onTop = saved?.alwaysOnTop ?? (sticky && settings.stickyAlwaysOnTop)

        let size = NSSize(width: saved?.width ?? (sticky ? 340 : 540), height: saved?.height ?? (sticky ? 380 : 560))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = onTop ? .floating : .normal
        window.minSize = NSSize(width: 260, height: 200)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self

        let state = NoteWindowState(alwaysOnTop: onTop)
        states[id] = state
        let root = NoteEditorView(session: session, model: model, windowState: state) { [weak self] on in
            self?.setAlwaysOnTop(id, on)
        }
        window.contentView = NSHostingView(rootView: root)

        window.setFrame(initialFrame(size: size, saved: saved, placement: settings.stickyPlacement), display: false)
        windows[id] = window
        bringToFront(window)
        saveGeometry(id, isOpen: true)
    }

    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
    }

    private func initialFrame(size: NSSize, saved: WindowGeometry?, placement: StickyPlacement) -> NSRect {
        func onScreen(_ r: NSRect) -> Bool {
            NSScreen.screens.contains { s in
                let i = s.visibleFrame.intersection(r)
                return !i.isNull && i.width * i.height >= r.width * r.height * 0.5
            }
        }
        if placement == .remember, let g = saved {
            let r = NSRect(x: g.x, y: g.y, width: g.width, height: g.height)
            if onScreen(r) { return r }       // monitor layout changed: fall through to a safe position
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch placement {
        case .nearCursor:
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x - size.width / 2, y: m.y - size.height / 2)
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24 - CGFloat(windows.count % 6) * 28)
        case .remember, .cascade:
            if let last = lastOrigin { origin = NSPoint(x: last.x + 28, y: last.y - 28) }
            else { origin = NSPoint(x: visible.minX + 120, y: visible.maxY - size.height - 100) }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        lastOrigin = origin
        return NSRect(origin: origin, size: size)
    }

    // MARK: Geometry (device-local)

    private func id(of window: NSWindow) -> UUID? { window.identifier.flatMap { UUID(uuidString: $0.rawValue) } }

    private func saveGeometry(_ id: UUID, isOpen: Bool) {
        guard let w = windows[id], let store = model.store else { return }
        let f = w.frame
        let g = WindowGeometry(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height,
                               isOpen: isOpen, alwaysOnTop: states[id]?.alwaysOnTop)
        try? store.index.setWindowGeometry(g, for: id)
    }

    private func scheduleGeometrySave(_ id: UUID) {
        geometryTasks[id]?.cancel()
        geometryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveGeometry(id, isOpen: true)
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let w = notification.object as? NSWindow, let id = id(of: w) { scheduleGeometrySave(id) }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow, let id = id(of: w) { scheduleGeometrySave(id) }
    }

    func applyFadeSetting() {
        for window in windows.values { updateOpacity(for: window) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { updateOpacity(for: window) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { updateOpacity(for: window) }
    }

    private func updateOpacity(for window: NSWindow) {
        let fade = model.settings?.fadeWhenUnfocused == true && !window.isKeyWindow
        window.alphaValue = fade ? 0.72 : 1
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = id(of: sender), let session = model.sessions[id] else { return true }
        switch session.state {
        case .conflict:
            let alert = NSAlert()
            alert.messageText = "“\(session.document.displayTitle)” was changed elsewhere"
            alert.informativeText = "Another app or Mac edited this note while you had unsaved changes. Nothing has been overwritten. Choose what to keep."
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Keep My Version")
            alert.addButton(withTitle: "Use Other Version")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                Task { @MainActor in
                    switch response {
                    case .alertFirstButtonReturn: _ = try? await session.resolveKeepingBoth()
                    case .alertSecondButtonReturn: await session.resolveKeepingMine()
                    case .alertThirdButtonReturn: session.resolveTakingDisk()
                    default: return
                    }
                    self?.windows[id]?.close()
                }
            }
            return false
        case .deletedOnDisk:
            let alert = NSAlert()
            alert.messageText = "“\(session.document.displayTitle)” was deleted elsewhere"
            alert.informativeText = "Recreate it to keep your text, or close and let it go. A copy of your latest text stays in recovery history either way."
            alert.addButton(withTitle: "Recreate Note")
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                Task { @MainActor in
                    switch response {
                    case .alertFirstButtonReturn: await session.recreate()
                    case .alertSecondButtonReturn:
                        self?.model.store?.backups.snapshot(id: id, data: Data(session.document.serialize().utf8), reason: .recovery)
                        session.abandon(keepingDraft: false)
                    default: return
                    }
                    self?.windows[id]?.close()
                }
            }
            return false
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "This note couldn't be saved"
            alert.informativeText = message + "\n\nYour changes are kept in a recovery draft."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Close Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                Task { @MainActor in
                    if response == .alertFirstButtonReturn { await session.retry(); if session.state != .clean { return } }
                    else if response == .alertSecondButtonReturn { session.abandon(keepingDraft: true) }
                    else { return }
                    self?.windows[id]?.close()
                }
            }
            return false
        default:
            return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = id(of: w) else { return }
        geometryTasks[id]?.cancel()
        if windows[id] != nil {
            // While quitting, keep "open" so sticky windows come back at next launch.
            saveGeometry(id, isOpen: model.isTerminating)
        }
        windows[id] = nil
        states[id] = nil
        let session = model.sessions[id]
        Task {
            await session?.flush()
            model.releaseSession(id)
        }
    }
}
