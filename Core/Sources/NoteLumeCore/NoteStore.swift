import Foundation

public enum StoreAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public enum StoreEvent: Sendable {
    /// Notes changed. `external` is true when found by reconciliation (edited
    /// elsewhere or synced), false for this app's own writes.
    case notesChanged(updated: Set<UUID>, removed: Set<UUID>, external: Bool)
    case availability(StoreAvailability)
    case problems([ReconcileReport.Problem])
    case conflictCopies(Int)
}

public enum SaveOutcome: Sendable {
    case saved(FileVersion)
    case conflict(DiskState)
}

public struct LabelOperationReport: Sendable, Equatable {
    public var changed: [UUID] = []
    /// Notes that could not be updated (edited concurrently, unreadable, …); retry later.
    public var skipped: [UUID] = []
}

public enum ConflictResolution: Sendable {
    /// Keep the original and import the copy as a separate note.
    case keepBoth
    /// Replace the original's content with the copy (original is saved to history first).
    case useCopy
    /// Delete the copy (its content is saved to history first).
    case discardCopy
}

/// Entry point for everything that touches notes: files, index, history,
/// file-system monitoring and change notifications.
public actor NoteStore {
    public nonisolated let repository: NoteRepository
    public nonisolated let index: NoteIndex
    public nonisolated let backups: BackupStore
    public nonisolated let recovery: RecoveryStore
    public nonisolated let notesDirectory: URL
    public nonisolated var mediaDirectory: URL { notesDirectory.appendingPathComponent("media", isDirectory: true) }

    private let reconciler: Reconciler
    private var monitor: DirectoryChangeMonitor?
    private var periodic: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<StoreEvent>.Continuation] = [:]
    private var reconciling = false
    private var reconcileAgain = false
    private var lastAvailability: StoreAvailability = .available
    private var lastProblems: [ReconcileReport.Problem] = []
    private var lastConflictCount = 0
    public private(set) var unrecognizedFiles: [URL] = []

    /// - Parameters:
    ///   - notesDirectory: user-chosen folder holding the Markdown files.
    ///   - supportDirectory: local, unsynced app data (index, history, drafts).
    public init(notesDirectory: URL, supportDirectory: URL, missingGrace: TimeInterval = 60) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        self.notesDirectory = notesDirectory
        backups = BackupStore(root: supportDirectory.appendingPathComponent("Backups", isDirectory: true))
        recovery = RecoveryStore(root: supportDirectory.appendingPathComponent("Recovery", isDirectory: true))
        index = try NoteIndex(databaseURL: supportDirectory.appendingPathComponent("index.sqlite"))
        try index.bind(to: notesDirectory)
        repository = FileNoteRepository(directory: notesDirectory, backups: backups)
        reconciler = Reconciler(repository: repository, index: index, backups: backups, missingGrace: missingGrace)
    }

    // MARK: Lifecycle

    /// Reconciles once, then starts watching. Safe to call more than once.
    public func start(watch: Bool = true, periodicInterval: TimeInterval = 300) async {
        await reconcile()
        guard watch, monitor == nil else { return }
        #if os(macOS)
        let watcher = DirectoryWatcher(directory: notesDirectory) { [weak self] in
            Task { await self?.reconcile() }
        }
        watcher.start()
        monitor = watcher
        #endif
        if periodicInterval > 0 {
            periodic = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(periodicInterval))
                    await self?.reconcile()
                }
            }
        }
    }

    public func stop() {
        monitor?.stop(); monitor = nil
        periodic?.cancel(); periodic = nil
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
    }

    public func events() -> AsyncStream<StoreEvent> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<StoreEvent>.makeStream(bufferingPolicy: .unbounded)
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(token) } }
        return stream
    }

    private func removeSubscriber(_ token: UUID) { subscribers[token] = nil }
    private func emit(_ event: StoreEvent) { for c in subscribers.values { c.yield(event) } }

    /// Call at launch, after wake and when the user asks to refresh. Overlapping
    /// requests are coalesced into at most one follow-up pass.
    public func reconcile() async {
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        repeat {
            reconcileAgain = false
            await reconcileOnce()
        } while reconcileAgain
        reconciling = false
    }

    private func reconcileOnce() async {
        do {
            let report = try await reconciler.reconcile()
            setAvailability(.available)
            if report.hasChanges {
                emit(.notesChanged(updated: Set(report.added + report.updated), removed: Set(report.removed), external: true))
            }
            if report.problems != lastProblems { lastProblems = report.problems; emit(.problems(report.problems)) }
            if report.conflictCopyCount != lastConflictCount { lastConflictCount = report.conflictCopyCount; emit(.conflictCopies(report.conflictCopyCount)) }
            unrecognizedFiles = report.unrecognizedFiles
        } catch let error as NoteError {
            // Offline drive / cloud folder: report it, change nothing.
            setAvailability(.unavailable(error.localizedDescription))
        } catch {
            setAvailability(.unavailable(error.localizedDescription))
        }
    }

    private func setAvailability(_ a: StoreAvailability) {
        guard a != lastAvailability else { return }
        lastAvailability = a
        emit(.availability(a))
    }

    // MARK: Notes

    @discardableResult
    public func create(body: String = "", labels: [String] = [], sticky: Bool = false,
                       color: String? = nil, title: String? = nil, markdown: Bool = true) async throws -> LoadedNote {
        let meta = NoteMetadata(title: title, labels: LabelNormalizer.normalize(labels), color: color, sticky: sticky, markdown: markdown)
        let loaded = try await repository.create(NoteDocument(metadata: meta, body: body))
        try index.upsert(loaded)
        emit(.notesChanged(updated: [meta.id], removed: [], external: false))
        return loaded
    }

    public func load(_ id: UUID) async throws -> LoadedNote { try await repository.read(id: id) }

    /// Guarded save: never overwrites a file that changed since `expecting`.
    public func save(_ document: NoteDocument, expecting: FileVersion?) async throws -> SaveOutcome {
        switch try await repository.write(document, expecting: expecting) {
        case .written(let version):
            var saved = document
            saved.markSaved()
            let loaded = LoadedNote(document: saved, version: version, url: notesDirectory.appendingPathComponent(NoteFileName.filename(for: document.metadata.id)))
            try index.upsert(loaded)
            emit(.notesChanged(updated: [document.metadata.id], removed: [], external: false))
            return .saved(version)
        case .conflict(let state):
            return .conflict(state)
        }
    }

    /// Read-modify-write of one note's metadata with automatic retry when the
    /// file changed underneath. Use for edits to notes that are not open.
    @discardableResult
    public func mutateMetadata(_ id: UUID, attempts: Int = 3, _ transform: @Sendable (inout NoteDocument) -> Void) async throws -> Bool {
        for _ in 0..<attempts {
            let loaded = try await repository.read(id: id)
            var doc = loaded.document
            guard doc.canEditMetadata else { return false }
            let before = doc.serialize()
            transform(&doc)
            if doc.serialize() == before { return true }
            doc.touch()
            if case .saved = try await save(doc, expecting: loaded.version) { return true }
        }
        return false
    }

    public func setLabels(_ labels: [String], for id: UUID) async throws {
        let normalized = LabelNormalizer.normalize(labels)
        try await mutateMetadata(id) { $0.metadata.labels = normalized }
    }

    /// Stores a validated PNG under a note-specific name and returns its relative Markdown path.
    public func storeMediaImage(_ data: Data, for noteID: UUID) throws -> String? {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.starts(with: pngSignature) else { return nil }
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())
        let name = "\(noteID.uuidString.lowercased())_\(suffix).png"
        try data.write(to: mediaDirectory.appendingPathComponent(name), options: .atomic)
        return "media/\(name)"
    }

    // MARK: Trash

    public func trash(_ id: UUID) async throws {
        try await repository.moveToTrash(id: id)
        try index.remove(id: id)
        recovery.clear(id)
        emit(.notesChanged(updated: [], removed: [id], external: false))
    }

    public func trashedNotes() async throws -> [TrashedNote] { try await repository.trashedNotes() }

    public func restore(_ id: UUID) async throws {
        try await repository.restoreFromTrash(id: id)
        await reconcile()
    }

    /// The caller is responsible for confirming with the user first.
    public func deletePermanently(_ id: UUID) async throws {
        try await repository.deletePermanently(id: id)
        removeMediaImages(for: id)
    }

    public func emptyTrash() async throws {
        for note in try await repository.trashedNotes() { try await deletePermanently(note.id) }
    }

    private func removeMediaImages(for noteID: UUID) {
        let prefix = noteID.uuidString.lowercased() + "_"
        let urls = (try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "png" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Labels

    public func renameLabel(_ old: String, to new: String) async throws -> LabelOperationReport {
        let target = LabelNormalizer.normalize([new]).first
        guard let target, target != old else { return LabelOperationReport() }
        return try await rewriteLabels(containing: old) { labels in
            LabelNormalizer.normalize(labels.map { $0 == old ? target : $0 })
        }
    }

    public func deleteLabel(_ label: String) async throws -> LabelOperationReport {
        try await rewriteLabels(containing: label) { $0.filter { $0 != label } }
    }

    private func rewriteLabels(containing label: String, _ transform: @escaping @Sendable ([String]) -> [String]) async throws -> LabelOperationReport {
        var report = LabelOperationReport()
        let hits = try index.search(SearchQuery(labels: [label], limit: 100_000))
        for hit in hits {
            let id = hit.note.id
            do {
                let ok = try await mutateMetadata(id) { $0.metadata.labels = transform($0.metadata.labels) }
                if ok { report.changed.append(id) } else { report.skipped.append(id) }
            } catch { report.skipped.append(id) }
        }
        return report
    }

    // MARK: Conflicts & imports

    public func conflictCopies() throws -> [ConflictCopyEntry] { try index.conflictCopies() }

    public func resolve(_ copy: ConflictCopyEntry, _ resolution: ConflictResolution) async throws {
        let copyDoc = try await repository.read(url: copy.url, filenameID: copy.originalID)
        let copyData = Data(copyDoc.document.serialize().utf8)
        backups.snapshot(id: copy.originalID, data: copyData, reason: .conflict)

        switch resolution {
        case .keepBoth:
            let meta = copyDoc.document.metadata
            _ = try await create(body: copyDoc.document.body, labels: meta.labels + ["conflict"], color: meta.color, title: meta.title)
        case .useCopy:
            let original = try await repository.read(id: copy.originalID)
            backups.snapshot(id: copy.originalID, data: Data(original.document.serialize().utf8), reason: .conflict)
            var replacement = original.document
            replacement.body = copyDoc.document.body
            if replacement.canEditMetadata { replacement.metadata = copyDoc.document.metadata; replacement.metadata.id = copy.originalID }
            replacement.touch()
            if case .conflict = try await save(replacement, expecting: original.version) {
                throw NoteError.coordination("The note changed while resolving; please try again.")
            }
        case .discardCopy:
            break
        }
        try FileNoteRepository.coordinatedDelete(copy.url)
        await reconcile()
    }

    /// Imports a Markdown file that is not UUID-named as a new note. The source file is left untouched.
    public func importFile(at url: URL) async throws -> LoadedNote {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw NoteError.notUTF8(url) }
        let probe = NoteDocument(text: text, filenameID: UUID())
        var meta = probe.hasFrontmatter ? probe.metadata : NoteMetadata()
        meta.id = UUID()
        let created = try await repository.create(NoteDocument(metadata: meta, body: probe.body))
        try index.upsert(created)
        emit(.notesChanged(updated: [meta.id], removed: [], external: false))
        return created
    }

    // MARK: Recovery

    public struct RecoveryCandidate: Sendable, Identifiable {
        public var id: UUID { draft.noteID }
        public var draft: RecoveryStore.Draft
        public var existsOnDisk: Bool
        /// Disk changed after the draft's base version was read.
        public var diskChangedSinceBase: Bool
    }

    /// Drafts left by a crash or forced quit that differ from what is on disk.
    public func recoveryCandidates() async -> [RecoveryCandidate] {
        var out: [RecoveryCandidate] = []
        for draft in recovery.allDrafts() {
            let draftHash = FileVersion.hash(of: Data(draft.text.utf8))
            if let loaded = try? await repository.read(id: draft.noteID) {
                if loaded.version.hash == draftHash { recovery.clear(draft.noteID); continue }
                out.append(RecoveryCandidate(draft: draft, existsOnDisk: true, diskChangedSinceBase: loaded.version.hash != draft.baseHash))
            } else {
                out.append(RecoveryCandidate(draft: draft, existsOnDisk: false, diskChangedSinceBase: false))
            }
        }
        return out
    }
}
