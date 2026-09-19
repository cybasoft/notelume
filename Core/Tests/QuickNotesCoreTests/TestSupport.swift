import Foundation
@testable import NoteLumeCore

/// A throwaway notes directory plus separate local-state directory.
final class Sandbox {
    let root: URL
    var notes: URL { root.appendingPathComponent("notes", isDirectory: true) }
    var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    var backupsDir: URL { support.appendingPathComponent("Backups", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeRepository() -> FileNoteRepository {
        FileNoteRepository(directory: notes, backups: BackupStore(root: backupsDir))
    }

    func url(_ id: UUID) -> URL { notes.appendingPathComponent(NoteFileName.filename(for: id)) }

    func writeRaw(_ text: String, id: UUID) throws {
        try text.write(to: url(id), atomically: true, encoding: .utf8)
    }

    func readRaw(_ id: UUID) throws -> String { try String(contentsOf: url(id), encoding: .utf8) }
}
