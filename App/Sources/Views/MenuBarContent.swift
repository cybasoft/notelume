import NoteLumeCore
import SwiftUI

/// Menubar interface: quick capture, search, sticky notes, reminders, recents and labels (requirements §9).
struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var recentNotes: [NoteSummary] = []
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let _ = model.changeTick   // re-query when notes change
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchResults = searchQuery.isEmpty ? [] : model.hits(matching: SearchQuery(text: searchQuery, limit: 5)).map(\.note)
        VStack(alignment: .leading, spacing: 0) {
            if model.phase != .ready {
                VStack(spacing: 10) {
                    Text("Choose a notes folder to get started.").foregroundStyle(.secondary)
                    Button("Choose Folder…") { openLibrary(); Task { await model.chooseFolder() } }
                }
                .padding(16)
            } else {
                actions
                Divider()
                searchField
                if !searchQuery.isEmpty {
                    if searchResults.isEmpty {
                        VStack(spacing: 6) {
                            Text("No notes match \"\(searchQuery)\"")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Clear Search") { query = "" }
                                .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .padding(.horizontal, 10)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            section("Results", searchResults)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            header("Recent")
                            if !model.initialIndexLoaded {
                                Text("Loading recent notes…")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                            } else if recentNotes.isEmpty {
                                HStack {
                                    Text("No recent notes").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Browse All") { openLibrary() }
                                        .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            } else {
                                ForEach(recentNotes) { note in
                                    MenuNoteRow(model: model, note: note, showReminder: false)
                                }
                            }
                            reminders
                            section("Sticky", model.hits(matching: SearchQuery(sticky: true, limit: 8)).map(\.note))
                            labels
                        }
                        .padding(.vertical, 6)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: MenuListHeightKey.self, value: proxy.size.height)
                        })
                    }
                    .frame(height: min(max(listHeight, 200), 520))
                    .onPreferenceChange(MenuListHeightKey.self) { listHeight = $0 }
                }
                Divider()
                footer
            }
        }
        .frame(width: 340)
        .onAppear(perform: refreshRecentNotes)
        .onChange(of: model.changeTick) { _, _ in refreshRecentNotes() }
        .onChange(of: model.initialIndexLoaded) { _, _ in refreshRecentNotes() }
        .onChange(of: model.settings?.menuBarRecentCount ?? 6) { _, _ in refreshRecentNotes() }
        .onChange(of: model.settings?.menuBarRecentSort ?? .updated) { _, _ in refreshRecentNotes() }
    }

    // MARK: Pieces

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.createNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                .keyboardShortcut("n")
            Button { model.createNote(sticky: true) } label: { Label("Sticky", systemImage: "pin") }
            Spacer()
            Button { openLibrary() } label: { Label("Browse All", systemImage: "square.grid.2x2") }
        }
        .padding(10)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search notes")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var searchResults: [NoteSummary] {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return [] }
        return model.hits(matching: SearchQuery(text: searchQuery, limit: 5)).map(\.note)
    }

    private func refreshRecentNotes() {
        let count = model.settings?.menuBarRecentCount ?? 6
        let sort = model.settings?.menuBarRecentSort.searchSort ?? .updated
        recentNotes = model.hits(matching: SearchQuery(limit: count, sort: sort)).map(\.note)
    }

    @ViewBuilder private var reminders: some View {
        let overdue = (model.reminderStatus?.overdue ?? []).compactMap { model.summary($0) }.sorted { ($0.reminder ?? .distantPast) < ($1.reminder ?? .distantPast) }
        let upcoming = (model.reminderStatus?.upcoming ?? []).compactMap { model.summary($0) }.sorted { ($0.reminder ?? .distantFuture) < ($1.reminder ?? .distantFuture) }
        if !overdue.isEmpty { section("Overdue", overdue, reminderStyle: true, tint: .red) }
        if !upcoming.isEmpty { section("Upcoming", Array(upcoming.prefix(6)), reminderStyle: true) }
    }

    @ViewBuilder private var labels: some View {
        if !model.labelCounts.isEmpty {
            header("Labels")
            FlowLabels(labels: model.labelCounts) { label in
                model.selection = .label(label)
                openLibrary()
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }

    private var footer: some View {
        HStack {
            if case .unavailable = model.availability {
                Label("Notes folder offline", systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("Settings…", action: showSettings).buttonStyle(.plain).font(.callout)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.callout)
        }
        .padding(10)
    }

    private func header(_ title: String, tint: Color = .secondary) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    @ViewBuilder private func section(_ title: String, _ notes: [NoteSummary], reminderStyle: Bool = false, tint: Color = .secondary) -> some View {
        if !notes.isEmpty {
            header(title, tint: tint)
            ForEach(notes) { note in
                MenuNoteRow(model: model, note: note, showReminder: reminderStyle)
            }
        }
    }

    private func openLibrary() {
        openWindow(id: "library")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MenuNoteRow: View {
    let model: AppModel
    let note: NoteSummary
    let showReminder: Bool
    @State private var hovering = false

    var body: some View {
        Button { model.openNote(note.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: NSColor(hex: note.color) ?? .tertiaryLabelColor)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title).lineLimit(1)
                    if showReminder, let r = note.reminder {
                        Text(r.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(r < Date() ? .red : .secondary)
                    } else if !note.preview.isEmpty {
                        Text(note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if note.sticky { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(note.sticky ? "Unpin from Sticky" : "Make Sticky") { model.setSticky(note.id, !note.sticky) }
            Menu("Labels") {
                ForEach(model.labelCounts) { lc in
                    Button { model.toggleLabel(lc.label, on: note.id) } label: {
                        if note.labels.contains(lc.label) { Label(lc.label, systemImage: "checkmark") } else { Text(lc.label) }
                    }
                }
            }
            Button("Move to Trash", role: .destructive) { model.trash(note.id) }
        }
    }
}

private struct FlowLabels: View {
    let labels: [LabelCount]
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels) { lc in
                    Button { pick(lc.label) } label: {
                        Text("\(lc.label) \(lc.count)").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
