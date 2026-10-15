import NoteLumeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let onHotKeysChanged: () -> Void

    var body: some View {
        if let settings = model.settings {
            TabView {
                GeneralSettings(model: model, settings: settings).tabItem { Label("General", systemImage: "gearshape") }
                EditorSettings(settings: settings).tabItem { Label("Editor", systemImage: "square.and.pencil") }
                WindowSettings(model: model, settings: settings).tabItem { Label("Notes", systemImage: "rectangle.on.rectangle") }
                ShortcutSettings(settings: settings, changed: onHotKeysChanged).tabItem { Label("Shortcuts", systemImage: "keyboard") }
                ReminderSettings(model: model).tabItem { Label("Reminders", systemImage: "bell") }
                DataSettings(model: model).tabItem { Label("Data", systemImage: "externaldrive") }
            }
            .frame(width: 520, height: 380)
            .padding(20)
        } else {
            VStack(spacing: 12) {
                Text("Choose a notes folder to configure NoteLume.")
                Button("Choose Folder…") { Task { await model.chooseFolder() } }
            }
            .frame(width: 420, height: 160)
        }
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @Bindable var settings: DeviceSettings

    var body: some View {
        Form {
            LabeledContent("Notes folder") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.folderURL?.path ?? "—").font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    HStack {
                        Button("Show in Finder") { if let u = model.folderURL { NSWorkspace.shared.open(u) } }
                        Button("Change…") { Task { await model.chooseFolder() } }
                    }
                }
            }
            Text("Each note is a Markdown file in this folder. Existing notes are kept when you change folders; copy or move the files yourself to bring them along.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show icon in the Dock", isOn: Binding(get: { settings.showInDock }, set: { settings.showInDock = $0; model.applyActivationPolicy() }))
            Toggle("Make notes searchable in Spotlight", isOn: Binding(get: { settings.spotlightEnabled }, set: {
                settings.spotlightEnabled = $0
                if let s = model.store { model.spotlight.reindexAll(from: s.index, enabled: $0) }
            }))
            Text("Spotlight receives titles, labels and a short preview only. NoteLume search never depends on it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Bindable var settings: DeviceSettings
    var body: some View {
        Form {
            Picker("Default mode for new notes", selection: $settings.editorMode) {
                ForEach(EditorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Both modes edit the same Markdown. Switching never changes your text. Metadata (labels, color, reminder) stays hidden above the note body and is preserved on save.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Shortcuts: ⌘B bold, ⌘I italic, ⌘E code. Click a checkbox to toggle it. ⌘-click a link to open it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct WindowSettings: View {
    let model: AppModel
    @Bindable var settings: DeviceSettings
    var body: some View {
        Form {
            Section {
                LabeledContent("Default note color") {
                    HStack(spacing: 8) {
                        Button {
                            settings.defaultNoteColor = nil
                        } label: {
                            Circle().strokeBorder(.secondary).frame(width: 22, height: 22)
                                .overlay {
                                    if settings.defaultNoteColor == nil {
                                        Image(systemName: "checkmark").font(.caption2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Automatic")
                        .accessibilityLabel("Automatic note color")
                        ForEach(NoteAppearance.presets, id: \.hex) { preset in
                            Button {
                                settings.defaultNoteColor = preset.hex
                            } label: {
                                Circle().fill(Color(nsColor: NSColor(hex: preset.hex)!))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if settings.defaultNoteColor == preset.hex {
                                            Image(systemName: "checkmark").font(.caption2)
                                                .foregroundStyle(.black.opacity(0.7))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                            .accessibilityLabel(preset.name)
                        }
                    }
                }
                ColorPicker(
                    "Custom note color",
                    selection: Binding(
                        get: { Color(nsColor: NSColor(hex: settings.defaultNoteColor) ?? .windowBackgroundColor) },
                        set: { settings.defaultNoteColor = NSColor($0).hexString }),
                    supportsOpacity: false)
            }
            Picker("Collection layout", selection: $settings.layout) {
                ForEach(CollectionLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.layout == .tiled {
                LabeledContent("Tile size") { Slider(value: $settings.tileSize, in: 140...340) }
            }
            Toggle("Show content previews on cards", isOn: $settings.showPreviews)
            Divider()
            Toggle("Sticky notes stay on top of other windows", isOn: $settings.stickyAlwaysOnTop)
            Toggle("Fade note windows when unfocused", isOn: Binding(
                get: { settings.fadeWhenUnfocused },
                set: { settings.fadeWhenUnfocused = $0; model.windows?.applyFadeSetting() }))
            Picker("Open note windows", selection: $settings.stickyPlacement) {
                ForEach(StickyPlacement.allCases) { Text($0.title).tag($0) }
            }
            Section("Menubar") {
                RecentCountInput(settings: settings)
                Picker("Recent order", selection: $settings.menuBarRecentSort) {
                    ForEach(RecentNoteSort.allCases) { Text($0.title).tag($0) }
                }
            }
            Text("Window positions and sizes are remembered per Mac and are never written to your note files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct RecentCountInput: View {
    @Bindable var settings: DeviceSettings
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Recent notes") {
            TextField("5-20", text: $value)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .accessibilityLabel("Number of recent notes, from 5 to 20")
                .help("Enter a number from 5 to 20")
                .onChange(of: value) { _, text in
                    if let count = Int(text), (5...20).contains(count) {
                        settings.menuBarRecentCount = count
                    }
                }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
        .onAppear { value = String(settings.menuBarRecentCount) }
    }

    private func commit() {
        let count = Int(value) ?? settings.menuBarRecentCount
        settings.menuBarRecentCount = min(20, max(5, count))
        value = String(settings.menuBarRecentCount)
    }
}

private struct ShortcutSettings: View {
    @Bindable var settings: DeviceSettings
    let changed: () -> Void

    var body: some View {
        Form {
            LabeledContent("New quick note") {
                HStack {
                    HotKeyRecorder(spec: Binding(get: { settings.newNoteHotKey }, set: { settings.newNoteHotKey = $0; changed() })).frame(width: 150, height: 24)
                    Button("Clear") { settings.newNoteHotKey = nil; changed() }.disabled(settings.newNoteHotKey == nil)
                }
            }
            LabeledContent("Search notes") {
                HStack {
                    HotKeyRecorder(spec: Binding(get: { settings.searchHotKey }, set: { settings.searchHotKey = $0; changed() })).frame(width: 150, height: 24)
                    Button("Clear") { settings.searchHotKey = nil; changed() }.disabled(settings.searchHotKey == nil)
                }
            }
            Text("Global shortcuts work from any app. Click a field and press the new combination (at least one modifier key).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ReminderSettings: View {
    let model: AppModel
    @State private var enabled = true

    var body: some View {
        Form {
            Toggle("Notify on this Mac", isOn: Binding(get: { enabled }, set: { v in
                enabled = v
                Task { await model.reminders?.setEnabled(v); await model.reconcileReminders() }
            }))
            Text("Reminders are stored in the note files, so when notes sync between Macs, each Mac with this switched on will notify. Turn it off on Macs that shouldn't.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("System permission") {
                switch model.reminderStatus?.permission {
                case .authorized: Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .denied:
                    HStack {
                        Label("Denied", systemImage: "xmark.circle").foregroundStyle(.red)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                default:
                    Button("Allow Notifications") { Task { await model.scheduler.requestPermission(); await model.reconcileReminders() } }
                }
            }
            Text("Reminders that came due while your Mac was off are shown once at launch, and always listed under Overdue.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { enabled = await model.reminders?.isEnabled() ?? true }
    }
}

private struct DataSettings: View {
    let model: AppModel
    @State private var rebuilding = false

    var body: some View {
        Form {
            Section("Search index") {
                Text("The search index and cache live only on this Mac and are rebuilt from your note files. Rebuilding never changes notes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(rebuilding ? "Rebuilding…" : "Rebuild Search Index") {
                    rebuilding = true
                    Task {
                        try? model.store?.index.clearAllDerivedData()
                        await model.reconcileNow()
                        rebuilding = false
                    }
                }
                .disabled(rebuilding)
            }
            Section("Local history and recovery") {
                Text("Earlier versions, deleted notes and unsaved-edit drafts are kept in this Mac's Application Support folder (not synced).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Local Data in Finder") {
                    if let dir = model.store?.index.databaseURL.deletingLastPathComponent() { NSWorkspace.shared.open(dir) }
                }
            }
            Section("Privacy") {
                Text("NoteLume never sends note content anywhere. If your notes folder is in iCloud Drive, Dropbox or similar, that service handles the files under its own privacy policy. Notes are stored unencrypted as readable Markdown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
