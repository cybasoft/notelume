import AppKit
import CoreSpotlight
import NoteLumeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) lazy var windows = NoteWindowManager(model: model)
    private var lastForegroundReconcile = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.windows = windows
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.model.reconcileNow() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.model.flushAll() }
        }
        Task {
            await model.bootstrap()
            registerHotKeys()
        }
    }

    /// Re-reads the shortcuts from settings. Called at launch and whenever they change.
    func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.register(id: HotKeyID.newNote, spec: model.settings?.newNoteHotKey) { [weak self] in
            // Quick capture: write the file immediately and open it, without raising the library window.
            self?.model.createNote()
        }
        center.register(id: HotKeyID.search, spec: model.settings?.searchHotKey) { [weak self] in
            self?.model.requestSearchFocus()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // External edits may have happened while the app was in the background.
        guard Date().timeIntervalSince(lastForegroundReconcile) > 2 else { return }
        lastForegroundReconcile = Date()
        Task { await model.reconcileNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openLibrary?() }
        return true
    }

    /// Flush every open note before quitting so no edit is ever lost to the debounce.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .ready else { return .terminateNow }
        Task {
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType, let id = SpotlightIndexer.noteID(from: userActivity) else { return false }
        model.openNote(id)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Opening a `.md` file from Finder imports it as a new note (the original is untouched).
        guard let store = model.store else { return }
        Task {
            for url in urls where url.pathExtension.lowercased() == "md" {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let note = try? await store.importFile(at: url) { model.openNote(note.document.metadata.id) }
            }
        }
    }
}
