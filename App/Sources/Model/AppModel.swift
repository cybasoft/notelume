import AppKit
import Observation
import NoteLumeCore
import SwiftUI

enum SidebarItem: Hashable {
    case all, sticky, upcoming, overdue
    case label(String)
    case trash, conflicts
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, needsFolder, ready, failed(String) }

    private(set) var phase: Phase = .launching
    private(set) var initialIndexLoaded = false
    private(set) var store: NoteStore?
    private(set) var settings: DeviceSettings?
    private(set) var reminders: ReminderCoordinator?
    private(set) var reminderStatus: ReminderStatus?

    var selection: SidebarItem = .all { didSet { refresh() } }
    var searchText = "" { didSet { refresh() } }
    private(set) var hits: [SearchHit] = []
    private(set) var allNoteCount = 0
    private(set) var stickyNoteCount = 0
    private(set) var trashNoteCount = 0
    private(set) var labelCounts: [LabelCount] = []
    private(set) var availability: StoreAvailability = .available
    private(set) var problems: [ReconcileReport.Problem] = []
    private(set) var conflictCopyCount = 0
    private(set) var recoveryCandidates: [NoteStore.RecoveryCandidate] = []
    private(set) var folderURL: URL?
    /// Set when the user must act on a recoverable error (shown as an alert).
    var lastError: String?

    private(set) var sessions: [UUID: NoteEditSession] = [:]
    private(set) var selectedNoteID: UUID?
    let folder = FolderAccess()
    let scheduler = UNScheduler()
    let spotlight = SpotlightIndexer()
    weak var windows: NoteWindowManager?
    private(set) var isTerminating = false
    /// Set by the library window so hotkeys and the menubar can bring it forward.
    var openLibrary: (() -> Void)?
    /// Incremented to ask the library window to focus its search field.
    private(set) var searchFocusTick = 0
    /// Bumped on every index change so views that query on demand (menubar) refresh.
    private(set) var changeTick = 0

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init() {
        scheduler.onOpenNote = { [weak self] id in self?.openNote(id) }
    }

    // MARK: Startup

    func bootstrap() async {
        if let url = folder.restore() { await start(directory: url) } else { phase = .needsFolder }
    }

    func chooseFolder() async {
        guard let url = folder.choose(startingAt: folderURL) else { return }
        await flushAll()
        windows?.closeAll()
        await start(directory: url)
    }

    private func start(directory: URL) async {
        initialIndexLoaded = false
        eventTask?.cancel()
        if let old = store { await old.stop() }
        sessions.removeAll()
        selectedNoteID = nil
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("NoteLume", isDirectory: true)
            let store = try NoteStore(notesDirectory: directory, supportDirectory: support)
            self.store = store
            folderURL = directory
            settings = DeviceSettings(index: store.index)
            reminders = ReminderCoordinator(index: store.index, scheduler: scheduler)
            phase = .ready

            let stream = await store.events()
            eventTask = Task { [weak self] in
                for await event in stream { await self?.handle(event) }
            }
            await store.start()
            refresh()
            await refreshTrashCount()
            initialIndexLoaded = true
            recoveryCandidates = await store.recoveryCandidates()
            await reconcileReminders()
            windows?.restoreStickyWindows()
            applyActivationPolicy()
            spotlight.reindexAll(from: store.index, enabled: settings?.spotlightEnabled ?? false)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Events

    private func handle(_ event: StoreEvent) async {
        switch event {
        case .notesChanged(let updated, let removed, let external):
            refresh()
            await refreshTrashCount()
            if let store, settings?.spotlightEnabled == true {
                spotlight.update(updated: updated, removed: removed, index: store.index)
            }
            if external {
                for id in updated.union(removed) {
                    if let s = sessions[id] { await s.diskDidChange() }
                }
            }
            await reconcileReminders()
        case .availability(let a):
            availability = a
        case .problems(let p):
            problems = p
        case .conflictCopies(let n):
            conflictCopyCount = n
        }
    }

    func reconcileReminders() async {
        guard let reminders else { return }
        reminderStatus = await reminders.reconcile()
    }

    /// Wake from sleep, app reactivation, manual refresh.
    func reconcileNow() async {
        await store?.reconcile()
        await reconcileReminders()
    }

    func requestSearchFocus() {
        searchFocusTick += 1
        selection = .all
        openLibrary?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Queries

    var effectiveQuery: SearchQuery {
        var q = SearchQuery(text: searchText)
        switch selection {
        case .sticky: q.sticky = true
        case .upcoming: q.reminder = .upcoming
        case .overdue: q.reminder = .overdue
        case .label(let l): q.labels = [l]
        case .all, .trash, .conflicts: break
        }
        return q
    }

    func refresh() {
        guard let store else { return }
        hits = (try? store.index.search(effectiveQuery)) ?? []
        allNoteCount = (try? store.index.noteCount()) ?? 0
        stickyNoteCount = (try? store.index.noteCount(sticky: true)) ?? 0
        labelCounts = (try? store.index.labelCounts()) ?? []
        changeTick += 1
    }

    func refreshTrashCount() async {
        guard let store else { trashNoteCount = 0; return }
        trashNoteCount = (try? await store.trashedNotes().count) ?? 0
    }

    func hits(matching query: SearchQuery) -> [SearchHit] {
        guard let store else { return [] }
        return (try? store.index.search(query)) ?? []
    }

    func summary(_ id: UUID) -> NoteSummary? { try? store?.index.summary(id: id) }

    // MARK: Notes

    func session(for id: UUID) async throws -> NoteEditSession {
        if let s = sessions[id] { return s }
        guard let store else { throw NoteError.notFound(id) }
        let loaded = try await store.load(id)
        if let session = sessions[id] { return session }
        let session = NoteEditSession(loaded: loaded, store: store)
        sessions[id] = session
        return session
    }

    func releaseSession(_ id: UUID) {
        if let s = sessions[id], !s.hasUnsavedChanges { sessions[id] = nil }
    }

    func openNote(_ id: UUID) {
        guard settings?.noteOpenMode == .library else {
            windows?.show(id)
            return
        }
        if !hits.contains(where: { $0.id == id }) || selection == .trash || selection == .conflicts {
            searchText = ""
            selection = .all
        }
        selectNote(id)
        openLibrary?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func selectNote(_ id: UUID?) {
        guard selectedNoteID != id else { return }
        let previous = selectedNoteID.flatMap { sessions[$0] }
        selectedNoteID = id
        Task {
            await previous?.flush()
            guard let id else { return }
            do { _ = try await session(for: id) }
            catch {
                if selectedNoteID == id { selectedNoteID = nil }
                lastError = error.localizedDescription
            }
        }
    }

    func setNoteOpenMode(_ mode: NoteOpenMode) {
        guard let settings, settings.noteOpenMode != mode else { return }
        settings.noteOpenMode = mode
        if mode == .library {
            windows?.closeAll()
            if selectedNoteID == nil { selectNote(hits.first?.id) }
            openLibrary?()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            Task { await flushAll() }
            if let selectedNoteID { windows?.show(selectedNoteID) }
            windows?.restoreStickyWindows()
        }
    }

    /// Creates the file immediately (valid frontmatter, UUID name) and opens it for typing.
    /// If currently inside a filter view (e.g. a label or sticky view), that filter is automatically applied.
    func createNote(labels: [String] = [], sticky: Bool = false, open: Bool = true) {
        guard let store else { return }
        var effectiveLabels = labels
        var effectiveSticky = sticky

        switch selection {
        case .label(let l):
            if effectiveLabels.isEmpty {
                effectiveLabels = [l]
            }
        case .sticky:
            effectiveSticky = true
        default:
            break
        }

        let markdown = settings?.editorMode != .source
        let color = settings?.defaultNoteColor
        let textColor = settings?.defaultTextColor
        Task {
            do {
                let note = try await store.create(
                    labels: effectiveLabels, sticky: effectiveSticky, color: color,
                    textColor: textColor, markdown: markdown)
                if open { openNote(note.document.metadata.id) }
            } catch { lastError = error.localizedDescription }
        }
    }

    func setSticky(_ id: UUID, _ sticky: Bool) {
        if let s = sessions[id] { s.updateMetadata { $0.sticky = sticky }; return }
        Task {
            do { _ = try await store?.mutateMetadata(id) { $0.metadata.sticky = sticky } } catch { lastError = error.localizedDescription }
        }
    }

    func toggleLabel(_ label: String, on id: UUID) {
        let current = summary(id)?.labels ?? []
        let new = current.contains(label) ? current.filter { $0 != label } : current + [label]
        setLabels(new, on: id)
    }

    func setLabels(_ labels: [String], on id: UUID) {
        let normalized = LabelNormalizer.normalize(labels)
        if let s = sessions[id] { s.updateMetadata { $0.labels = normalized }; return }
        Task { do { try await store?.setLabels(normalized, for: id) } catch { lastError = error.localizedDescription } }
    }

    func trash(_ id: UUID) {
        guard let store else { return }
        Task {
            do {
                windows?.close(id)
                if selectedNoteID == id { selectedNoteID = nil }
                sessions[id] = nil
                try await store.trash(id)
            } catch { lastError = error.localizedDescription }
        }
    }

    func renameLabel(_ old: String, to new: String) {
        guard let store else { return }
        Task {
            do {
                let r = try await store.renameLabel(old, to: new)
                if !r.skipped.isEmpty { lastError = "\(r.skipped.count) note(s) changed while renaming and were skipped. Try again." }
                if selection == .label(old) { selection = .label(new) }
            } catch { lastError = error.localizedDescription }
        }
    }

    func deleteLabel(_ label: String) {
        guard let store else { return }
        Task {
            do {
                _ = try await store.deleteLabel(label)
                if selection == .label(label) { selection = .all }
            } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: Recovery

    func restoreDraft(_ candidate: NoteStore.RecoveryCandidate) {
        Task {
            do {
                let id = candidate.draft.noteID
                if !candidate.existsOnDisk, let store {
                    // Note file is gone: recreate it from the draft so nothing typed is lost.
                    let doc = NoteDocument(text: candidate.draft.text, filenameID: id)
                    _ = try await store.repository.create(doc)
                    await store.reconcile()
                }
                let s = try await session(for: id)
                await s.applyRecoveredDraft(candidate.draft)
                openNote(id)
                recoveryCandidates.removeAll { $0.id == candidate.id }
            } catch { lastError = error.localizedDescription }
        }
    }

    func discardDraft(_ candidate: NoteStore.RecoveryCandidate) {
        // History keeps a copy so "discard" is never destructive.
        store?.backups.snapshot(id: candidate.draft.noteID, data: Data(candidate.draft.text.utf8), reason: .recovery)
        store?.recovery.clear(candidate.draft.noteID)
        recoveryCandidates.removeAll { $0.id == candidate.id }
    }

    // MARK: Lifecycle

    /// Saves every open note. Used on quit, folder change and sleep.
    func flushAll() async {
        for s in sessions.values { await s.flush() }
    }

    func prepareForTermination() async {
        isTerminating = true
        await flushAll()
        await store?.stop()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings?.showInDock == false ? .accessory : .regular)
    }
}
