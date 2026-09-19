import Foundation
import Testing
@testable import NoteLumeCore

@Suite struct RepositoryTests {
    @Test func createWritesUUIDNamedFileWithFrontmatter() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let doc = NoteDocument(metadata: NoteMetadata(labels: ["a"]), body: "# Hello\n")
        let loaded = try await repo.create(doc)
        let raw = try sb.readRaw(doc.metadata.id)
        #expect(raw.hasPrefix("---\nschema: 1\n"))
        #expect(raw.hasSuffix("---\n# Hello\n"))
        #expect(loaded.url.lastPathComponent == doc.metadata.id.uuidString.lowercased() + ".md")
        #expect(NoteFileName.id(fromFilename: loaded.url.lastPathComponent) == doc.metadata.id)
    }

    @Test func createNeverOverwrites() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let doc = NoteDocument(body: "first")
        _ = try await repo.create(doc)
        var other = NoteDocument(metadata: doc.metadata, body: "second")
        other.body = "second"
        await #expect(throws: NoteError.self) { _ = try await repo.create(other) }
        #expect(try sb.readRaw(doc.metadata.id).hasSuffix("first"))
    }

    @Test func saveWithMatchingVersionSucceedsAndSnapshotsPrevious() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let loaded = try await repo.create(NoteDocument(body: "v1"))
        var doc = loaded.document
        doc.body = "v2"; doc.touch()
        guard case .written(let v2) = try await repo.write(doc, expecting: loaded.version) else { Issue.record("expected write"); return }
        #expect(v2 != loaded.version)
        #expect(try sb.readRaw(doc.metadata.id).hasSuffix("v2"))

        let history = BackupStore(root: sb.backupsDir).versions(for: doc.metadata.id)
        #expect(history.count == 1)
        #expect(String(data: try BackupStore(root: sb.backupsDir).data(for: history[0]), encoding: .utf8)?.hasSuffix("v1") == true)
    }

    @Test func staleSaveReportsConflictAndLeavesDiskUntouched() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let loaded = try await repo.create(NoteDocument(body: "base"))
        let id = loaded.document.metadata.id

        // Another app (or cloud sync) edits the file.
        let external = loaded.document.serialize().replacingOccurrences(of: "base", with: "external edit")
        try sb.writeRaw(external, id: id)

        var mine = loaded.document
        mine.body = "my edit"
        let result = try await repo.write(mine, expecting: loaded.version)
        guard case .conflict(.modified(let disk)) = result else { Issue.record("expected conflict, got \(result)"); return }
        #expect(disk.document.body == "external edit")
        #expect(try sb.readRaw(id) == external)
    }

    @Test func saveAfterExternalDeleteReportsDeleted() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let loaded = try await repo.create(NoteDocument(body: "x"))
        try FileManager.default.removeItem(at: loaded.url)
        let result = try await repo.write(loaded.document, expecting: loaded.version)
        guard case .conflict(.deleted) = result else { Issue.record("expected deleted"); return }
        #expect(!FileManager.default.fileExists(atPath: loaded.url.path))
    }

    @Test func identicalContentIsNotRewritten() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let loaded = try await repo.create(NoteDocument(body: "same"))
        let before = try FileManager.default.attributesOfItem(atPath: loaded.url.path)[.modificationDate] as! Date
        try await Task.sleep(for: .milliseconds(30))
        _ = try await repo.write(loaded.document, expecting: loaded.version)
        let after = try FileManager.default.attributesOfItem(atPath: loaded.url.path)[.modificationDate] as! Date
        #expect(before == after)
    }

    @Test func listingClassifiesFiles() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let a = UUID(), b = UUID()
        try sb.writeRaw("a", id: a)
        try sb.writeRaw("b", id: b)
        try "dup".write(to: sb.notes.appendingPathComponent("\(a.uuidString.lowercased()) 2.md"), atomically: true, encoding: .utf8)
        try "dbx".write(to: sb.notes.appendingPathComponent("\(b.uuidString.lowercased()) (Bob's MacBook's conflicted copy 2026-10-11).md"), atomically: true, encoding: .utf8)
        try "random".write(to: sb.notes.appendingPathComponent("shopping.md"), atomically: true, encoding: .utf8)
        try "x".write(to: sb.notes.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "x".write(to: sb.notes.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let l = try await repo.listing()
        #expect(Set(l.notes.map(\.id)) == [a, b])
        #expect(Set(l.conflictCopies.map(\.originalID)) == [a, b])
        #expect(l.unrecognized.map(\.lastPathComponent) == ["shopping.md"])
    }

    @Test func unavailableDirectoryThrowsWithoutSideEffects() async throws {
        let sb = try Sandbox()
        let missing = sb.root.appendingPathComponent("gone")
        let repo = FileNoteRepository(directory: missing, backups: BackupStore(root: sb.backupsDir))
        await #expect(throws: NoteError.self) { _ = try await repo.listing() }
        await #expect(throws: NoteError.self) { _ = try await repo.create(NoteDocument()) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func trashRestoreAndPermanentDelete() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let loaded = try await repo.create(NoteDocument(body: "# Bye\n"))
        let id = loaded.document.metadata.id

        try await repo.moveToTrash(id: id)
        #expect(!FileManager.default.fileExists(atPath: sb.url(id).path))
        let trashed = try await repo.trashedNotes()
        #expect(trashed.map(\.id) == [id])
        #expect(trashed[0].title == "Bye")
        // Hidden trash folder is not picked up as notes.
        #expect(try await repo.listing().notes.isEmpty)

        try await repo.restoreFromTrash(id: id)
        #expect(FileManager.default.fileExists(atPath: sb.url(id).path))

        try await repo.moveToTrash(id: id)
        try await repo.deletePermanently(id: id)
        #expect(try await repo.trashedNotes().isEmpty)
        // …but its content remains recoverable from local history.
        #expect(!BackupStore(root: sb.backupsDir).versions(for: id).isEmpty)
    }

    @Test func nonUTF8FileIsReportedNotModified() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let id = UUID()
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41, 0xC3, 0x28])
        try bytes.write(to: sb.url(id))
        await #expect(throws: NoteError.self) { _ = try await repo.read(id: id) }
        #expect(try Data(contentsOf: sb.url(id)) == bytes)
    }
}

@Suite struct NamingTests {
    @Test func conflictNameDetection() {
        let id = UUID(); let s = id.uuidString.lowercased()
        #expect(NoteFileName.id(fromFilename: "\(s).md") == id)
        #expect(NoteFileName.id(fromFilename: "\(s.uppercased()).MD") == id)
        #expect(NoteFileName.id(fromFilename: "\(s) 2.md") == nil)
        #expect(NoteFileName.conflictOriginal(fromFilename: "\(s) 2.md") == id)
        #expect(NoteFileName.conflictOriginal(fromFilename: "\(s) (conflicted copy).md") == id)
        #expect(NoteFileName.conflictOriginal(fromFilename: "\(s).md") == nil)
        #expect(NoteFileName.conflictOriginal(fromFilename: "notes.md") == nil)
    }
}

@Suite struct BackupStoreTests {
    @Test func dedupesThrottlesAndPrunes() throws {
        let sb = try Sandbox()
        var r = BackupStore.Retention(); r.maxVersionsPerNote = 3; r.editInterval = 60
        let store = BackupStore(root: sb.backupsDir, retention: r)
        let id = UUID(); let t0 = Date()

        #expect(store.snapshot(id: id, data: Data("a".utf8), reason: .edit, now: t0) != nil)
        #expect(store.snapshot(id: id, data: Data("a".utf8), reason: .edit, now: t0.addingTimeInterval(500)) != nil) // identical → returns existing
        #expect(store.versions(for: id).count == 1)
        #expect(store.snapshot(id: id, data: Data("b".utf8), reason: .edit, now: t0.addingTimeInterval(10)) == nil)   // throttled
        #expect(store.snapshot(id: id, data: Data("b".utf8), reason: .delete, now: t0.addingTimeInterval(10)) != nil) // non-edit never throttled

        for i in 0..<5 { store.snapshot(id: id, data: Data("v\(i)".utf8), reason: .conflict, now: t0.addingTimeInterval(1000 + Double(i))) }
        let versions = store.versions(for: id)
        #expect(versions.count == 3)
        #expect(String(data: try store.data(for: versions[0]), encoding: .utf8) == "v4")   // newest first
    }
}
