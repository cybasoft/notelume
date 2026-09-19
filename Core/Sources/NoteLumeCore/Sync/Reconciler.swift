import Foundation

public struct ReconcileReport: Sendable, Equatable {
    public var added: [UUID] = []
    public var updated: [UUID] = []
    public var removed: [UUID] = []
    public var conflictCopyCount = 0
    public var unrecognizedFiles: [URL] = []
    /// Cloud files still downloading; they are picked up on a later pass.
    public var pendingDownloads = 0
    /// Files that could not be read or indexed (name, reason). The files are left untouched.
    public var problems: [Problem] = []

    public struct Problem: Sendable, Equatable {
        public var url: URL
        public var message: String
    }

    public var hasChanges: Bool { !added.isEmpty || !updated.isEmpty || !removed.isEmpty }
}

/// Brings the local index in line with the notes directory (requirements §7, §10).
///
/// Filesystem events only *trigger* this; correctness comes from comparing the
/// directory with the index using modification metadata plus content hashes.
public final class Reconciler: Sendable {
    private let repository: NoteRepository
    private let index: NoteIndex
    /// A file must stay missing this long before its index rows are dropped, so
    /// transient cloud-sync states never make notes vanish.
    private let missingGrace: TimeInterval
    private let backups: BackupStore?
    private let readConcurrency = 8

    public init(repository: NoteRepository, index: NoteIndex, backups: BackupStore? = nil, missingGrace: TimeInterval = 60) {
        self.repository = repository
        self.index = index
        self.backups = backups
        self.missingGrace = missingGrace
    }

    public func reconcile(now: Date = Date()) async throws -> ReconcileReport {
        // Throws if the folder is offline/unmounted: in that case we change nothing.
        let listing = try await repository.listing()
        let indexed = try index.indexedFiles()
        var report = ReconcileReport()
        report.unrecognizedFiles = listing.unrecognized
        report.conflictCopyCount = listing.conflictCopies.count

        // 1. Decide which files need reading.
        var toRead: [NoteFileEntry] = []
        for entry in listing.notes {
            let known = indexed[entry.id]
            if !entry.isDownloaded {
                report.pendingDownloads += 1
                if known != nil { try index.markNotDownloaded(entry) }
                continue
            }
            if let known, known.modified == entry.modified, known.size == entry.size,
               known.isDownloaded, known.missingSince == nil {
                continue
            }
            toRead.append(entry)
        }

        // 2. Read them (bounded parallelism), compare hashes, then index in one transaction.
        var changed: [LoadedNote] = []
        var results: [(NoteFileEntry, Result<LoadedNote, Error>)] = []
        await withTaskGroup(of: (NoteFileEntry, Result<LoadedNote, Error>).self) { group in
            var iterator = toRead.makeIterator()
            var running = 0
            while running < readConcurrency, let entry = iterator.next() {
                group.addTask { [repository] in (entry, await Result { try await repository.read(url: entry.url, filenameID: entry.id) }) }
                running += 1
            }
            for await result in group {
                results.append(result)
                if let entry = iterator.next() {
                    group.addTask { [repository] in (entry, await Result { try await repository.read(url: entry.url, filenameID: entry.id) }) }
                }
            }
        }

        for (entry, result) in results {
            switch result {
            case .failure(let error):
                report.problems.append(.init(url: entry.url, message: error.localizedDescription))
            case .success(let loaded):
                if let known = indexed[entry.id], known.hash == loaded.version.hash {
                    try index.touchFile(id: entry.id, modified: loaded.version.modified, size: loaded.version.size)
                } else {
                    changed.append(loaded)
                    if indexed[entry.id] == nil {
                        report.added.append(entry.id)
                    } else {
                        report.updated.append(entry.id)
                        // Keep a copy of versions that arrive from outside the app (sync, other editors).
                        backups?.snapshot(id: entry.id, data: Data(loaded.document.serialize().utf8), reason: .external)
                    }
                }
            }
        }
        try index.upsert(changed)

        // 3. Missing files: mark first, drop index rows only after the grace period.
        let present = Set(listing.notes.map(\.id))
        let missing = indexed.keys.filter { !present.contains($0) }
        try index.markMissing(missing, since: now)
        report.removed = try index.purgeMissing(olderThan: now.addingTimeInterval(-missingGrace))

        // 4. Conflict copies from cloud providers.
        try index.replaceConflictCopies(listing.conflictCopies)
        return report
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
