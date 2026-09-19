import Foundation
import Observation

/// Editing state for one open note: debounced autosave, crash-recovery drafts,
/// and handling of changes made to the file by other apps or cloud sync.
///
/// Data-safety rules (requirements §4, §10, §11):
/// - A save is only ever applied to the exact disk version the edit started from.
/// - If the file changed underneath unsaved edits, nothing is overwritten; the
///   session enters `.conflict` and the user chooses how to resolve it.
/// - Both sides of a conflict are always preserved (disk state, or local edits in history).
@MainActor
@Observable
public final class NoteEditSession {
    public enum State: Equatable, Sendable {
        case clean
        case dirty
        case saving
        /// File changed on disk while this session has unsaved edits.
        case conflict
        /// File was deleted or moved to trash elsewhere while open.
        case deletedOnDisk
        case failed(String)
    }

    public let noteID: UUID
    public private(set) var document: NoteDocument
    public private(set) var state: State = .clean
    /// Incremented whenever `document` is replaced from outside the editor
    /// (external change adopted, conflict resolved, recovery). Editors reload their text on change.
    public private(set) var revision = 0
    /// The disk version captured when a conflict was detected.
    public private(set) var conflictingDisk: LoadedNote?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private var version: FileVersion?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var draftWrite: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private let draftDelay: Duration

    public init(loaded: LoadedNote, store: NoteStore,
                autosaveDelay: Duration = .milliseconds(800), draftDelay: Duration = .milliseconds(250)) {
        self.noteID = loaded.document.metadata.id
        self.document = loaded.document
        self.version = loaded.version
        self.store = store
        self.autosaveDelay = autosaveDelay
        self.draftDelay = draftDelay
    }

    public var hasUnsavedChanges: Bool { state == .dirty || state == .saving || state == .conflict || state == .deletedOnDisk }

    // MARK: Editing

    public func setBody(_ body: String) {
        guard body != document.body else { return }
        document.body = body
        didEdit()
    }

    public func updateMetadata(_ change: (inout NoteMetadata) -> Void) {
        guard document.canEditMetadata else { return }
        let before = document.metadata
        change(&document.metadata)
        guard document.metadata != before else { return }
        didEdit()
    }

    /// Creates the metadata block for a note that lacks one, without touching its text.
    public func initializeMetadata() {
        guard !document.hasFrontmatter else { return }
        document.initializeMetadata()
        didEdit()
    }

    /// Repairs a frontmatter ID that disagrees with the filename.
    public func adoptFilenameID() {
        document.adoptFilenameID(noteID)
        didEdit()
    }

    private func didEdit() {
        document.touch()
        generation += 1
        switch state {
        case .conflict, .deletedOnDisk:
            // Keep protecting the edits in a draft; do not try to save over the conflict.
            scheduleDraft()
        default:
            state = .dirty
            scheduleDraft()
            scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func scheduleDraft() {
        draftWrite?.cancel()
        draftWrite = Task { [weak self, draftDelay] in
            try? await Task.sleep(for: draftDelay)
            guard !Task.isCancelled else { return }
            self?.writeDraft()
        }
    }

    private func writeDraft() {
        store.recovery.write(.init(noteID: noteID, baseHash: version?.hash,
                                   text: document.serialize(), savedAt: Date()))
    }

    // MARK: Saving

    /// Saves any pending edits immediately. Call when a window closes, the app
    /// resigns active, or the app is about to terminate.
    public func flush() async {
        autosave?.cancel(); draftWrite?.cancel()
        if hasUnsavedChanges { writeDraft() }   // synchronous safety net before any awaiting
        await inFlight?.value
        if state == .dirty { await saveNow() }
    }

    public func saveNow() async {
        if let inFlight { await inFlight.value }
        guard state == .dirty else { return }
        let task = Task { await self.performSave() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performSave() async {
        autosave?.cancel()
        let snapshot = document
        let savedGeneration = generation
        state = .saving
        do {
            switch try await store.save(snapshot, expecting: version) {
            case .saved(let newVersion):
                version = newVersion
                if generation == savedGeneration {
                    document.markSaved()
                    state = .clean
                    draftWrite?.cancel()
                    store.recovery.clear(noteID)
                } else {
                    // The user kept typing during the save: keep their newer text,
                    // remember what is now on disk, and save again.
                    document.adoptSavedState(from: snapshot)
                    state = .dirty
                    scheduleAutosave()
                }
            case .conflict(.modified(let disk)):
                conflictingDisk = disk
                state = .conflict
                writeDraft()
            case .conflict(.deleted):
                state = .deletedOnDisk
                writeDraft()
            }
        } catch {
            state = .failed(error.localizedDescription)
            writeDraft()
        }
    }

    /// Retry after a transient failure (e.g. folder was offline).
    public func retry() async {
        guard case .failed = state else { return }
        state = .dirty
        await saveNow()
    }

    // MARK: External changes

    /// Called when the store reports that this note's file changed outside the session.
    public func diskDidChange() async {
        guard state != .saving else { return }   // our own write; the next event will settle it
        do {
            let disk = try await store.load(noteID)
            if disk.version == version { return }
            if disk.version.hash == version?.hash { version = disk.version; return }
            if disk.document.serialize() == document.serialize() {
                version = disk.version       // someone wrote the same text we have
                if state != .conflict { state = .clean }
                conflictingDisk = nil
                return
            }
            switch state {
            case .clean, .failed:
                adopt(disk)
            case .dirty:
                autosave?.cancel()
                conflictingDisk = disk
                state = .conflict
                writeDraft()
            case .conflict:
                conflictingDisk = disk
            case .saving, .deletedOnDisk:
                conflictingDisk = disk
                state = .conflict
            }
        } catch NoteError.notFound {
            if state == .clean { state = .deletedOnDisk }
            else if state == .dirty { autosave?.cancel(); state = .deletedOnDisk; writeDraft() }
        } catch {
            // Transient read problems (sync in progress): ignore; the next event or periodic pass retries.
        }
    }

    private func adopt(_ disk: LoadedNote) {
        document = disk.document
        version = disk.version
        conflictingDisk = nil
        state = .clean
        generation += 1
        revision += 1
        store.recovery.clear(noteID)
    }

    // MARK: Conflict resolution

    /// Keep local edits; the disk version is saved to history first.
    public func resolveKeepingMine() async {
        guard state == .conflict, let disk = conflictingDisk else { return }
        store.backups.snapshot(id: noteID, data: Data(disk.document.serialize().utf8), reason: .conflict)
        version = disk.version
        conflictingDisk = nil
        state = .dirty
        await saveNow()
    }

    /// Discard local edits in favour of the disk version; local edits are saved to history first.
    public func resolveTakingDisk() {
        guard state == .conflict, let disk = conflictingDisk else { return }
        store.backups.snapshot(id: noteID, data: Data(document.serialize().utf8), reason: .conflict)
        adopt(disk)
    }

    /// Keep both: local edits become a new note labelled "conflict"; this note adopts the disk version.
    @discardableResult
    public func resolveKeepingBoth() async throws -> UUID? {
        guard state == .conflict, let disk = conflictingDisk else { return nil }
        let copy = try await store.create(body: document.body,
                                          labels: document.metadata.labels + ["conflict"],
                                          color: document.metadata.color,
                                          title: document.metadata.title.map { $0 + " (conflict)" })
        adopt(disk)
        return copy.document.metadata.id
    }

    /// Stops tracking unsaved edits so the window can close. With `keepingDraft`
    /// the recovery draft stays on disk and is offered again at next launch.
    public func abandon(keepingDraft: Bool) {
        autosave?.cancel(); draftWrite?.cancel()
        if keepingDraft { writeDraft() } else { store.recovery.clear(noteID) }
        conflictingDisk = nil
        state = .clean
    }

    /// The file was deleted elsewhere: write the current text back as the note.
    public func recreate() async {
        guard state == .deletedOnDisk else { return }
        version = nil
        state = .dirty
        await saveNow()
    }

    // MARK: Crash recovery

    /// Applies a recovered draft as unsaved local edits. The disk state is checked
    /// *before* autosave can run, so a file that changed since the draft's base is
    /// never overwritten: the session opens in `.conflict` instead.
    public func applyRecoveredDraft(_ draft: RecoveryStore.Draft) async {
        autosave?.cancel()
        document = NoteDocument(text: draft.text, filenameID: noteID)
        generation += 1
        revision += 1
        conflictingDisk = nil

        if let disk = try? await store.load(noteID) {
            version = disk.version
            if let base = draft.baseHash, base != disk.version.hash {
                conflictingDisk = disk
                state = .conflict
                writeDraft()
                return
            }
            state = .dirty
            writeDraft()
            scheduleAutosave()
        } else {
            version = nil
            state = .deletedOnDisk   // note vanished; offer to recreate it from the draft
            writeDraft()
        }
    }
}
