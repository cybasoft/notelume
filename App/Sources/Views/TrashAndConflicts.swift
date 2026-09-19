import NoteLumeCore
import SwiftUI

struct TrashView: View {
    let model: AppModel
    @State private var items: [TrashedNote] = []
    @State private var confirmDelete: TrashedNote?
    @State private var confirmEmpty = false
    @State private var loaded = false

    var body: some View {
        Group {
            if items.isEmpty && loaded {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Deleted notes stay here until you remove them permanently."))
            } else {
                List {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline)
                                Text("Deleted \(item.deleted.formatted(.relative(presentation: .named)))" + (item.labels.isEmpty ? "" : " · " + item.labels.joined(separator: ", ")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { act { try await model.store?.restore(item.id) } }
                            Button("Delete Permanently…", role: .destructive) { confirmDelete = item }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .task { await load() }
        .toolbar {
            ToolbarItem {
                Button("Empty Trash…", role: .destructive) { confirmEmpty = true }.disabled(items.isEmpty)
            }
        }
        .confirmationDialog("Permanently delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let item = confirmDelete { act { try await model.store?.deletePermanently(item.id) } }
                confirmDelete = nil
            }
        } message: {
            Text("The file is removed from the notes folder. A final copy is kept in this Mac's local history for 90 days.")
        }
        .confirmationDialog("Permanently delete all \(items.count) notes in the Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { act { try await model.store?.emptyTrash() } }
        } message: {
            Text("This can't be undone from the app. Final copies stay in local history for 90 days.")
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { model.lastError = error.localizedDescription }
            await load()
        }
    }

    private func load() async {
        items = (try? await model.store?.trashedNotes()) ?? []
        loaded = true
        await model.refreshTrashCount()
    }
}

struct ConflictsView: View {
    let model: AppModel
    @State private var copies: [ConflictCopyEntry] = []

    var body: some View {
        Group {
            if copies.isEmpty {
                ContentUnavailableView("No conflicts", systemImage: "checkmark.circle", description: Text("Conflicting copies created by your sync service appear here for review."))
            } else {
                List(copies, id: \.url) { copy in
                    ConflictRow(model: model, copy: copy) { Task { await reload() } }
                }
            }
        }
        .task { await reload() }
        .onChange(of: model.conflictCopyCount) { _, _ in Task { await reload() } }
    }

    private func reload() async { copies = (try? await model.store?.conflictCopies()) ?? [] }
}

private struct ConflictRow: View {
    let model: AppModel
    let copy: ConflictCopyEntry
    let done: () -> Void
    @State private var title = ""
    @State private var original = ""
    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.isEmpty ? copy.originalID.uuidString.lowercased() : title).font(.headline)
                Spacer()
                Text(copy.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text("A sync service saved a second version of this note (\(copy.modified.formatted(.relative(presentation: .named)))). Nothing has been overwritten.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                preview("Current note", original)
                preview("Conflicting copy", other)
            }
            HStack {
                Button("Keep Both") { resolve(.keepBoth) }
                    .help("Imports the copy as a separate note labelled “conflict”.")
                Button("Use Copy Instead") { resolve(.useCopy) }
                    .help("Replaces the note with the copy. The current text stays in history.")
                Button("Discard Copy", role: .destructive) { resolve(.discardCopy) }
                    .help("Deletes the copy file. Its text stays in history.")
            }
        }
        .padding(.vertical, 6)
        .task {
            if let store = model.store {
                if let loaded = try? await store.load(copy.originalID) { title = loaded.document.displayTitle; original = loaded.document.body }
                if let c = try? await store.repository.read(url: copy.url, filenameID: copy.originalID) { other = c.document.body }
            }
        }
    }

    private func preview(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView { Text(text.isEmpty ? "—" : text).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 110)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func resolve(_ r: ConflictResolution) {
        Task {
            do { try await model.store?.resolve(copy, r) } catch { model.lastError = error.localizedDescription }
            done()
        }
    }
}
