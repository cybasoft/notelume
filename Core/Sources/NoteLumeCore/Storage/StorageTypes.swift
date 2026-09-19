import CryptoKit
import Foundation

public struct FileVersion: Equatable, Sendable, Hashable {
    public var hash: String
    public var modified: Date
    public var size: Int

    public init(hash: String, modified: Date, size: Int) {
        self.hash = hash
        self.modified = modified
        self.size = size
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LoadedNote: Sendable {
    public var document: NoteDocument
    public var version: FileVersion
    public var url: URL
}

public enum NoteError: Error, LocalizedError, Sendable {
    case directoryUnavailable(URL)
    case notFound(UUID)
    case alreadyExists(UUID)
    case unreadable(URL, reason: String)
    case notUTF8(URL)
    case coordination(String)
    case trashCollision(UUID)

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let u):
            return "The notes folder “\(u.lastPathComponent)” is not available. If it is on a cloud drive or external volume, make sure it is online. No notes were changed."
        case .notFound(let id): return "Note \(id.uuidString) could not be found."
        case .alreadyExists(let id): return "A note with ID \(id.uuidString) already exists."
        case .unreadable(let u, let r): return "“\(u.lastPathComponent)” could not be read: \(r)"
        case .notUTF8(let u): return "“\(u.lastPathComponent)” is not valid UTF-8 text. The file was left untouched."
        case .coordination(let m): return "File access failed: \(m)"
        case .trashCollision(let id): return "Cannot restore \(id.uuidString): a note with that ID already exists."
        }
    }
}

/// What a guarded write found on disk instead of the expected version.
public enum DiskState: Sendable {
    case modified(LoadedNote)
    case deleted
}

public enum WriteResult: Sendable {
    case written(FileVersion)
    /// Disk content differs from what the caller based its edit on; nothing was written.
    case conflict(DiskState)
}

// MARK: - Naming

public enum NoteFileName {
    public static let fileExtension = "md"

    public static func filename(for id: UUID) -> String { id.uuidString.lowercased() + "." + fileExtension }

    /// `UUID.md` → UUID. Returns nil for anything else.
    public static func id(fromFilename name: String) -> UUID? {
        guard name.lowercased().hasSuffix("." + fileExtension) else { return nil }
        return UUID(uuidString: String(name.dropLast(fileExtension.count + 1)))
    }

    /// Detects cloud-provider conflict copies such as
    /// `UUID 2.md`, `UUID (conflicted copy).md` or `UUID (Bob's Mac's conflicted copy 2026-10-11).md`.
    public static func conflictOriginal(fromFilename name: String) -> UUID? {
        guard name.lowercased().hasSuffix("." + fileExtension) else { return nil }
        let stem = String(name.dropLast(fileExtension.count + 1))
        guard stem.count > 36 else { return nil }
        let prefix = String(stem.prefix(36))
        guard let id = UUID(uuidString: prefix) else { return nil }
        let rest = stem.dropFirst(36)
        guard let f = rest.first, f == " " || f == "(" || f == "-" || f == "_" else { return nil }
        return id
    }
}

// MARK: - Directory listing

public struct NoteFileEntry: Sendable, Equatable {
    public var id: UUID
    public var url: URL
    public var modified: Date
    public var created: Date
    public var size: Int
    /// False for cloud files whose content is not yet on this Mac.
    public var isDownloaded: Bool
}

public struct ConflictCopyEntry: Sendable, Equatable {
    public var originalID: UUID
    public var url: URL
    public var modified: Date
}

public struct DirectoryListing: Sendable {
    public var notes: [NoteFileEntry] = []
    public var conflictCopies: [ConflictCopyEntry] = []
    /// Markdown files that are not UUID-named; reported, never modified.
    public var unrecognized: [URL] = []
}
