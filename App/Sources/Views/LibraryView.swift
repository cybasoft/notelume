import NoteLumeCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?

    var body: some View {
        // A plain two-pane layout instead of NavigationSplitView: its restored/ideal sizing produced a
        // layout far taller than the window, leaving the sidebar and list scrolled out of view.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                banners
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search notes")
        .modifier(SearchFocus(tick: model.searchFocusTick))
        .alert("Rename Label", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $renameText)
            Button("Rename") { if let old = renaming { model.renameLabel(old, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("This updates every note that uses the label. Renaming to an existing label merges them.")
        }
        .confirmationDialog("Remove this label from all notes?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Remove “\(deleting ?? "")”", role: .destructive) { if let l = deleting { model.deleteLabel(l) }; deleting = nil }
        } message: {
            Text("The notes themselves are kept.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Library") {
                Label("All Notes", systemImage: "note.text")
                    .badge(model.allNoteCount)
                    .tag(SidebarItem.all)
                Label("Sticky", systemImage: "pin")
                    .badge(model.stickyNoteCount)
                    .tag(SidebarItem.sticky)
                Label("Upcoming Reminders", systemImage: "bell")
                    .badge(model.reminderStatus?.upcoming.count ?? 0)
                    .tag(SidebarItem.upcoming)
                Label("Overdue", systemImage: "bell.badge")
                    .badge(model.reminderStatus?.overdue.count ?? 0)
                    .tag(SidebarItem.overdue)
            }
            Section("Labels") {
                if model.labelCounts.isEmpty {
                    Text("No labels yet").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.labelCounts) { lc in
                    Label(lc.label, systemImage: "tag")
                        .badge(lc.count)
                        .contextMenu {
                            Button("New Note in “\(lc.label)”") { model.createNote(labels: [lc.label]) }
                            Divider()
                            Button("Rename…") { renameText = lc.label; renaming = lc.label }
                            Button("Remove from All Notes…", role: .destructive) { deleting = lc.label }
                        }
                        .tag(SidebarItem.label(lc.label))
                }
            }
            Section {
                if model.conflictCopyCount > 0 {
                    Label("Conflicts", systemImage: "exclamationmark.triangle")
                        .badge(model.conflictCopyCount)
                        .tag(SidebarItem.conflicts)
                }
                Label("Trash", systemImage: "trash")
                    .badge(model.trashNoteCount)
                    .tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
    }

    private var title: String {
        switch model.selection {
        case .all: "All Notes"
        case .sticky: "Sticky Notes"
        case .upcoming: "Upcoming Reminders"
        case .overdue: "Overdue"
        case .label(let l): l
        case .trash: "Trash"
        case .conflicts: "Sync Conflicts"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.selection {
        case .trash: TrashView(model: model)
        case .conflicts: ConflictsView(model: model)
        default:
            if model.hits.isEmpty {
                emptyState
            } else {
                NoteCollectionView(model: model, hits: model.hits)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView {
                Label("No notes here", systemImage: "note.text")
            } description: {
                Text(model.selection == .all ? "Create your first note with ⌘N." : "Nothing matches this view yet.")
            } actions: {
                Button(emptyStateButtonTitle) { model.createNote() }
            }
        }
    }

    private var emptyStateButtonTitle: String {
        switch model.selection {
        case .label(let l): "New Note in “\(l)”"
        case .sticky: "New Sticky Note"
        default: "New Note"
        }
    }

    private var newNoteHelp: String {
        switch model.selection {
        case .label(let l): "New note with label “\(l)” (⌘N)"
        case .sticky: "New sticky note (⌘N)"
        default: "New note (⌘N)"
        }
    }

    @ViewBuilder private var banners: some View {
        if case .unavailable(let message) = model.availability {
            Banner(icon: "externaldrive.badge.exclamationmark", tint: .orange, text: message) {
                Button("Retry") { Task { await model.reconcileNow() } }
                Button("Choose Folder…") { Task { await model.chooseFolder() } }
            }
        }
        if !model.problems.isEmpty {
            Banner(icon: "doc.badge.ellipsis", tint: .yellow,
                   text: "\(model.problems.count) file(s) couldn't be read and were left untouched: \(model.problems.prefix(2).map { $0.url.lastPathComponent }.joined(separator: ", "))\(model.problems.count > 2 ? "…" : "")") {
                EmptyView()
            }
        }
        if model.reminderStatus?.permission == .denied, model.reminderStatus?.enabledOnThisDevice == true,
           !(model.reminderStatus?.upcoming.isEmpty ?? true) {
            Banner(icon: "bell.slash", tint: .orange, text: "Notifications are turned off for NoteLume, so reminders won't alert you. Reminders still appear in the menubar.") {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let settings = model.settings {
            ToolbarItemGroup {
                Picker("Layout", selection: Binding(get: { settings.layout }, set: { settings.layout = $0 })) {
                    Label("Stacked", systemImage: "list.bullet.rectangle").tag(CollectionLayout.stacked)
                    Label("Tiled", systemImage: "square.grid.2x2").tag(CollectionLayout.tiled)
                }
                .pickerStyle(.segmented)
                .help("Stacked cards or a tiled grid")

                Button {
                    settings.editorMode = settings.editorMode == .visual ? .source : .visual
                } label: {
                    Image(systemName: settings.editorMode == .visual ? "eye" : "chevron.left.forwardslash.chevron.right")
                }
                .help(settings.editorMode == .visual ? "Editor: visual. Click for raw Markdown source." : "Editor: source. Click for visual editing.")

                Button { model.createNote() } label: { Image(systemName: "square.and.pencil") }
                    .help(newNoteHelp)
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}

/// Focuses the toolbar search field when the global search shortcut fires (macOS 15+;
/// on macOS 14 the shortcut still brings the library forward).
private struct SearchFocus: ViewModifier {
    let tick: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: tick) { _, _ in focused = true }
        } else {
            content
        }
    }
}
