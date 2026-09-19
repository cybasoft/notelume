import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey: needs no
/// accessibility permission and works inside the App Sandbox.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x514E5448   // 'QNTH'

    func register(id: UInt32, spec: HotKeySpec?, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        guard let spec else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeyID {
    static let newNote: UInt32 = 1
    static let search: UInt32 = 2
}

// MARK: - Recorder

/// Click, then press the desired combination. Requires at least one modifier.
struct HotKeyRecorder: NSViewRepresentable {
    @Binding var spec: HotKeySpec?

    func makeNSView(context: Context) -> RecorderField {
        let v = RecorderField()
        v.onChange = { spec = $0 }
        return v
    }

    func updateNSView(_ view: RecorderField, context: Context) {
        view.current = spec
        view.needsDisplay = true
    }

    final class RecorderField: NSView {
        var current: HotKeySpec?
        var onChange: ((HotKeySpec?) -> Void)?
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool { recording = false; return true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) { recording = false; return }
            if event.keyCode == UInt16(kVK_Delete) { onChange?(nil); recording = false; return }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { NSSound.beep(); return }
            var carbon: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
            let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
            onChange?(HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key))
            recording = false
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? "Type shortcut…" : (current?.display ?? "Click to record")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: current == nil && !recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}
