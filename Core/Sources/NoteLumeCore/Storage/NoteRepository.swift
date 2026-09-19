import Foundation

public struct TrashedNote: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var labels: [String]
    public var deleted: Date
    public var url: URL
}

/// Persistence boundary for notes (requirements §1, §13). The UI and index talk
/// only to this protocol, so storage can change without touching the editor.
public protocol NoteRepository: Sendable {
    var directory: URL { get }

    func listing() async throws -> DirectoryListing
    func read(id: UUID) async throws -> LoadedNote
    func read(url: URL, filenameID: UUID) async throws -> LoadedNote

    /// Writes a brand-new note; fails with `alreadyExists` rather than overwriting.
    func create(_ document: NoteDocument) async throws -> LoadedNote

    /// Writes `document` only if the file on disk still matches `expecting`
    /// (the version the edit was based on). Otherwise reports a conflict and
    /// leaves the file untouched.
    func write(_ document: NoteDocument, expecting: FileVersion?) async throws -> WriteResult

    func moveToTrash(id: UUID) async throws
    func trashedNotes() async throws -> [TrashedNote]
    func restoreFromTrash(id: UUID) async throws
    func deletePermanently(id: UUID) async throws
}

public final class FileNoteRepository: NoteRepository, @unchecked Sendable {
    public let directory: URL
    private let backups: BackupStore
    private let queue = DispatchQueue(label: "notelume.repository", qos: .utility, attributes: .concurrent)

    static let trashFolderName = ".trash"
    private var trashDirectory: URL { directory.appendingPathComponent(Self.trashFolderName, isDirectory: true) }

    public init(directory: URL, backups: BackupStore) {
        self.directory = directory
        self.backups = backups
    }

    // MARK: Listing

    public func listing() async throws -> DirectoryListing {
        try await blocking { [directory] in
            try Self.ensureAvailable(directory)
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
                                          .creationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
            let urls: [URL]
            do {
                urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            } catch {
                throw NoteError.directoryUnavailable(directory)
            }

            var result = DirectoryListing()
            for url in urls {
                var name = url.lastPathComponent
                var placeholder = false
                // Legacy iCloud placeholder: ".<name>.icloud"
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                    placeholder = true
                } else if name.hasPrefix(".") {
                    continue
                }
                guard name.lowercased().hasSuffix("." + NoteFileName.fileExtension) else { continue }

                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { continue }
                let realURL = placeholder ? directory.appendingPathComponent(name) : url
                let modified = values?.contentModificationDate ?? Date()

                var downloaded = !placeholder
                if let status = values?.ubiquitousItemDownloadingStatus, status != .current { downloaded = false }
                if !downloaded { try? fm.startDownloadingUbiquitousItem(at: realURL) }

                if let id = NoteFileName.id(fromFilename: name) {
                    result.notes.append(NoteFileEntry(
                        id: id, url: realURL, modified: modified,
                        created: values?.creationDate ?? modified,
                        size: values?.fileSize ?? 0, isDownloaded: downloaded))
                } else if let original = NoteFileName.conflictOriginal(fromFilename: name) {
                    result.conflictCopies.append(ConflictCopyEntry(originalID: original, url: realURL, modified: modified))
                } else {
                    result.unrecognized.append(realURL)
                }
            }
            return result
        }
    }

    // MARK: Reading

    public func read(id: UUID) async throws -> LoadedNote {
        try await read(url: noteURL(id), filenameID: id)
    }

    public func read(url: URL, filenameID: UUID) async throws -> LoadedNote {
        try await blocking {
            guard FileManager.default.fileExists(atPath: url.path) else { throw NoteError.notFound(filenameID) }
            let data = try Self.coordinatedRead(url)
            return try Self.makeLoaded(data: data, url: url, id: filenameID)
        }
    }

    // MARK: Writing

    public func create(_ document: NoteDocument) async throws -> LoadedNote {
        let id = document.metadata.id
        let url = noteURL(id)
        let data = Data(document.serialize().utf8)
        return try await blocking { [self] in
            try Self.ensureAvailable(directory)
            switch try Self.guardedWrite(url: url, id: id, data: data, expecting: nil, mustNotExist: true, backups: backups) {
            case .written:
                return try Self.makeLoaded(data: data, url: url, id: id)
            case .conflict:
                throw NoteError.alreadyExists(id)
            }
        }
    }

    public func write(_ document: NoteDocument, expecting: FileVersion?) async throws -> WriteResult {
        let id = document.metadata.id
        let url = noteURL(id)
        let data = Data(document.serialize().utf8)
        return try await blocking { [self] in
            try Self.ensureAvailable(directory)
            return try Self.guardedWrite(url: url, id: id, data: data, expecting: expecting, mustNotExist: false, backups: backups)
        }
    }

    // MARK: Trash

    public func moveToTrash(id: UUID) async throws {
        try await blocking { [self] in
            let src = noteURL(id)
            let fm = FileManager.default
            guard fm.fileExists(atPath: src.path) else { throw NoteError.notFound(id) }
            try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let dst = trashDirectory.appendingPathComponent(NoteFileName.filename(for: id))

            try Self.coordinatedMove(from: src, to: dst) { srcURL, dstURL in
                if let data = try? Data(contentsOf: srcURL) { backups.snapshot(id: id, data: data, reason: .delete) }
                if fm.fileExists(atPath: dstURL.path) {
                    // An older trashed copy with the same ID: keep it in history, never silently drop it.
                    if let old = try? Data(contentsOf: dstURL) { backups.snapshot(id: id, data: old, reason: .delete) }
                    try fm.removeItem(at: dstURL)
                }
                try fm.moveItem(at: srcURL, to: dstURL)
            }
        }
    }

    public func trashedNotes() async throws -> [TrashedNote] {
        try await blocking { [self] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: trashDirectory.path) else { return [] }
            let urls = try fm.contentsOfDirectory(at: trashDirectory,
                                                  includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
            return urls.compactMap { url in
                guard let id = NoteFileName.id(fromFilename: url.lastPathComponent),
                      let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
                let doc = NoteDocument(text: text, filenameID: id)
                let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
                return TrashedNote(id: id, title: doc.displayTitle, labels: doc.metadata.labels,
                                   deleted: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? Date(), url: url)
            }.sorted { $0.deleted > $1.deleted }
        }
    }

    public func restoreFromTrash(id: UUID) async throws {
        try await blocking { [self] in
            let fm = FileManager.default
            let src = trashDirectory.appendingPathComponent(NoteFileName.filename(for: id))
            let dst = noteURL(id)
            guard fm.fileExists(atPath: src.path) else { throw NoteError.notFound(id) }
            guard !fm.fileExists(atPath: dst.path) else { throw NoteError.trashCollision(id) }
            try Self.coordinatedMove(from: src, to: dst) { s, d in try fm.moveItem(at: s, to: d) }
        }
    }

    public func deletePermanently(id: UUID) async throws {
        try await blocking { [self] in
            let fm = FileManager.default
            let src = trashDirectory.appendingPathComponent(NoteFileName.filename(for: id))
            guard fm.fileExists(atPath: src.path) else { throw NoteError.notFound(id) }
            // Last-resort copy stays in local history until retention expires.
            if let data = try? Data(contentsOf: src) { backups.snapshot(id: id, data: data, reason: .delete) }
            try Self.coordinatedDelete(src)
        }
    }

    // MARK: Helpers

    func noteURL(_ id: UUID) -> URL { directory.appendingPathComponent(NoteFileName.filename(for: id)) }

    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    static func ensureAvailable(_ directory: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isReadableFile(atPath: directory.path) else {
            throw NoteError.directoryUnavailable(directory)
        }
    }

    static func makeLoaded(data: Data, url: URL, id: UUID) throws -> LoadedNote {
        guard let text = String(data: data, encoding: .utf8) else { throw NoteError.notUTF8(url) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? Date()
        let created = (attrs?[.creationDate] as? Date) ?? modified
        let doc = NoteDocument(text: text, filenameID: id, fileDates: (created, modified))
        let version = FileVersion(hash: FileVersion.hash(of: data), modified: modified, size: data.count)
        return LoadedNote(document: doc, version: version, url: url)
    }

    // MARK: Coordinated IO

    static func coordinatedRead(_ url: URL) throws -> Data {
        var coordError: NSError?
        var outcome: Result<Data, Error> = .failure(NoteError.coordination("read did not run"))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { target in
            outcome = Result { try Data(contentsOf: target) }
        }
        if let coordError { throw NoteError.coordination(coordError.localizedDescription) }
        do { return try outcome.get() } catch let e as NoteError { throw e } catch {
            throw NoteError.unreadable(url, reason: error.localizedDescription)
        }
    }

    /// The core of conflict-safe saving: inside file coordination, re-read the
    /// current file, compare it with what the edit was based on, and only then
    /// replace it atomically (requirements §11).
    static func guardedWrite(url: URL, id: UUID, data: Data, expecting: FileVersion?,
                             mustNotExist: Bool, backups: BackupStore) throws -> WriteResult {
        var coordError: NSError?
        var outcome: Result<WriteResult, Error> = .failure(NoteError.coordination("write did not run"))
        let fm = FileManager.default

        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            outcome = Result {
                let exists = fm.fileExists(atPath: target.path)
                var previous: Data?
                if exists {
                    previous = try Data(contentsOf: target)
                    let currentHash = FileVersion.hash(of: previous!)

                    if currentHash == FileVersion.hash(of: data) {
                        // Already identical on disk: nothing to write, no churn for sync clients.
                        return .written(try versionOf(target, data: data))
                    }
                    if mustNotExist { return .conflict(.modified(try makeLoaded(data: previous!, url: target, id: id))) }
                    guard let expecting else {
                        return .conflict(.modified(try makeLoaded(data: previous!, url: target, id: id)))
                    }
                    if currentHash != expecting.hash {
                        return .conflict(.modified(try makeLoaded(data: previous!, url: target, id: id)))
                    }
                } else if expecting != nil {
                    return .conflict(.deleted)
                }

                if let previous { backups.snapshot(id: id, data: previous, reason: .edit) }
                try data.write(to: target, options: .atomic)
                return .written(try versionOf(target, data: data))
            }
        }
        if let coordError { throw NoteError.coordination(coordError.localizedDescription) }
        return try outcome.get()
    }

    private static func versionOf(_ url: URL, data: Data) throws -> FileVersion {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileVersion(hash: FileVersion.hash(of: data), modified: (attrs[.modificationDate] as? Date) ?? Date(), size: data.count)
    }

    static func coordinatedMove(from src: URL, to dst: URL, _ body: (URL, URL) throws -> Void) throws {
        var coordError: NSError?
        var outcome: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &coordError
        ) { s, d in outcome = Result { try body(s, d) } }
        if let coordError { throw NoteError.coordination(coordError.localizedDescription) }
        try outcome.get()
    }

    static func coordinatedDelete(_ url: URL) throws {
        var coordError: NSError?
        var outcome: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { target in
            outcome = Result { try FileManager.default.removeItem(at: target) }
        }
        if let coordError { throw NoteError.coordination(coordError.localizedDescription) }
        try outcome.get()
    }
}
