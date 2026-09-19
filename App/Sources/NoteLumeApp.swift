import AppKit
import NoteLumeCore
import SwiftUI

@main
struct NoteLumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("NoteLume", id: "library") {
            RootView(model: delegate.model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { delegate.model.createNote() }
                    .keyboardShortcut("n")
                    .disabled(delegate.model.phase != .ready)
                Button("New Sticky Note") { delegate.model.createNote(sticky: true) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(delegate.model.phase != .ready)
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Visual / Source Editor") {
                    if let s = delegate.model.settings { s.editorMode = s.editorMode == .visual ? .source : .visual }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Refresh from Disk") { Task { await delegate.model.reconcileNow() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: .constant(true)) {
            MenuBarContent(model: delegate.model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model, onHotKeysChanged: { delegate.registerHotKeys() })
        }
    }
}
