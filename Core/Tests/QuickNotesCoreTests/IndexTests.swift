import Foundation
import Testing
@testable import NoteLumeCore

private func makeNote(_ repo: FileNoteRepository, title: String? = nil, body: String, labels: [String] = [],
                      sticky: Bool = false, reminder: Date? = nil) async throws -> LoadedNote {
    var meta = NoteMetadata(title: title, labels: labels, reminder: reminder, sticky: sticky)
    meta.updated = Date()
    return try await repo.create(NoteDocument(metadata: meta, body: body))
}

@Suite struct IndexTests {
    func fixture() throws -> (Sandbox, FileNoteRepository, NoteIndex, Reconciler) {
        let sb = try Sandbox()
        let repo = sb.makeRepository()
        let index = try NoteIndex(databaseURL: sb.support.appendingPathComponent("index.sqlite"))
        return (sb, repo, index, Reconciler(repository: repo, index: index, missingGrace: 0))
    }

    @Test func reconcileIndexesNewAndChangedFilesOnly() async throws {
        let (sb, repo, index, rec) = try fixture()
        let a = try await makeNote(repo, body: "# Alpha\nfirst")
        let b = try await makeNote(repo, body: "# Beta\nsecond")

        var r = try await rec.reconcile()
        #expect(Set(r.added) == [a.document.metadata.id, b.document.metadata.id])
        #expect(try index.noteCount() == 2)

        r = try await rec.reconcile()
        #expect(!r.hasChanges)

        // External edit, as from another editor or a sync client.
        var edited = b.document
        edited.body = "# Beta\nchanged text"
        edited.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(edited.serialize(), id: edited.metadata.id)
        r = try await rec.reconcile()
        #expect(r.updated == [edited.metadata.id])
        #expect(try index.search(SearchQuery(text: "changed")).count == 1)
        #expect(try index.search(SearchQuery(text: "second")).isEmpty)
    }

    @Test func mtimeChangeWithSameContentDoesNotReindex() async throws {
        let (sb, repo, _, rec) = try fixture()
        let a = try await makeNote(repo, body: "same")
        _ = try await rec.reconcile()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: a.url.path)
        let r = try await rec.reconcile()
        #expect(!r.hasChanges)
        _ = sb
    }

    @Test func missingFilesAreDroppedOnlyAfterGraceAndNeverDeleteFiles() async throws {
        let sb = try Sandbox(); let repo = sb.makeRepository()
        let index = try NoteIndex(databaseURL: sb.support.appendingPathComponent("index.sqlite"))
        let rec = Reconciler(repository: repo, index: index, missingGrace: 60)
        let a = try await makeNote(repo, body: "keep me")
        let id = a.document.metadata.id
        let t0 = Date()
        _ = try await rec.reconcile(now: t0)

        try FileManager.default.removeItem(at: a.url)
        var r = try await rec.reconcile(now: t0.addingTimeInterval(5))
        #expect(r.removed.isEmpty)
        #expect(try index.search(SearchQuery()).isEmpty)           // hidden from lists immediately
        #expect(try index.summary(id: id) != nil)                  // but row retained during grace

        // File comes back (sync finished): it is restored without re-read churn.
        try sb.writeRaw(a.document.serialize(), id: id)
        r = try await rec.reconcile(now: t0.addingTimeInterval(10))
        #expect(try index.search(SearchQuery()).count == 1)

        try FileManager.default.removeItem(at: a.url)
        _ = try await rec.reconcile(now: t0.addingTimeInterval(20))
        r = try await rec.reconcile(now: t0.addingTimeInterval(100))
        #expect(r.removed == [id])
    }

    @Test func unavailableDirectoryLeavesIndexUntouched() async throws {
        let (sb, repo, index, rec) = try fixture()
        _ = try await makeNote(repo, body: "x")
        _ = try await rec.reconcile()
        try FileManager.default.moveItem(at: sb.notes, to: sb.root.appendingPathComponent("offline"))
        await #expect(throws: NoteError.self) { _ = try await rec.reconcile() }
        #expect(try index.noteCount() == 1)
    }

    @Test func indexRebuildsFromFilesAfterLoss() async throws {
        let (sb, repo, index, rec) = try fixture()
        _ = try await makeNote(repo, title: "Persisted", body: "body text", labels: ["x"])
        _ = try await rec.reconcile()
        try index.clearAllDerivedData()
        #expect(try index.noteCount() == 0)
        _ = try await rec.reconcile()
        let hits = try index.search(SearchQuery(text: "persisted"))
        #expect(hits.count == 1)
        #expect(hits[0].note.labels == ["x"])
        _ = sb
    }

    @Test func corruptDatabaseIsQuarantinedAndRecreated() throws {
        let sb = try Sandbox()
        let url = sb.support.appendingPathComponent("index.sqlite")
        try Data("this is not a database".utf8).write(to: url)
        let index = try NoteIndex(databaseURL: url)
        #expect(try index.noteCount() == 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sb.support.path)
        #expect(leftovers.contains { $0.contains(".corrupt-") })
    }

    @Test func searchRanksTitleAndSupportsPrefixDiacriticsAndUnsafeInput() async throws {
        let (sb, repo, index, rec) = try fixture()
        defer { withExtendedLifetime(sb) {} }
        _ = try await makeNote(repo, body: "# Payments\nretry logic for timeouts")
        _ = try await makeNote(repo, body: "# Misc\nmentions payments once in the body text")
        _ = try await makeNote(repo, body: "# Café résumé\nnaïve notes")
        _ = try await rec.reconcile()

        let hits = try index.search(SearchQuery(text: "payments"))
        #expect(hits.count == 2)
        #expect(hits[0].note.title == "Payments")                      // title match outranks body match
        #expect(hits[1].snippet?.contains(SearchHit.highlightStart) == true)

        #expect(try index.search(SearchQuery(text: "pay")).count == 2)  // prefix
        #expect(try index.search(SearchQuery(text: "cafe resume")).count == 1)  // diacritics folded
        #expect(try index.search(SearchQuery(text: "naive")).count == 1)
        // FTS syntax characters are inert.
        for nasty in ["\"", "AND OR NOT", "foo*bar", "(", "NEAR(", "-", "a:b", "'; DROP TABLE note;--"] {
            _ = try index.search(SearchQuery(text: nasty))
        }
        #expect(try index.noteCount() == 3)
    }

    @Test func labelAndStatusFilters() async throws {
        let (sb, repo, index, rec) = try fixture()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        _ = try await makeNote(repo, body: "one", labels: ["backend", "debugging"], sticky: true)
        _ = try await makeNote(repo, body: "two", labels: ["backend"], reminder: now.addingTimeInterval(3600))
        _ = try await makeNote(repo, body: "three", labels: ["ünï code", "c++ & more"], reminder: now.addingTimeInterval(-3600))
        _ = try await rec.reconcile()

        #expect(try index.search(SearchQuery(labels: ["backend"])).count == 2)
        #expect(try index.search(SearchQuery(labels: ["backend", "debugging"], matchAllLabels: true)).count == 1)
        #expect(try index.search(SearchQuery(labels: ["backend", "ünï code"], matchAllLabels: false)).count == 3)
        #expect(try index.search(SearchQuery(labels: ["c++ & more"])).count == 1)
        #expect(try index.search(SearchQuery(sticky: true)).count == 1)
        #expect(try index.search(SearchQuery(reminder: .upcoming), now: now).count == 1)
        #expect(try index.search(SearchQuery(reminder: .overdue), now: now).count == 1)
        #expect(try index.search(SearchQuery(reminder: .noReminder), now: now).count == 1)
        #expect(try index.search(SearchQuery(text: "two", labels: ["backend"])).count == 1)
        #expect(Set(try index.labelCounts().map(\.label)) == ["backend", "debugging", "ünï code", "c++ & more"])
    }

    @Test func deviceStateSurvivesRebuildAndIsLocal() async throws {
        let (sb, repo, index, _) = try fixture()
        let n = try await makeNote(repo, body: "w")
        let id = n.document.metadata.id
        try index.setWindowGeometry(WindowGeometry(x: 10, y: 20, width: 300, height: 200), for: id)
        try index.clearAllDerivedData()
        #expect(try index.windowGeometry(for: id)?.width == 300)
        // Geometry never lands in the note file.
        #expect(!(try sb.readRaw(id)).contains("300"))
        #expect(!(try sb.readRaw(id)).lowercased().contains("geometry"))
    }

    @Test func switchingNotesFolderResetsDerivedAndDeviceState() async throws {
        let (sb, repo, index, rec) = try fixture()
        try index.bind(to: sb.notes)
        let n = try await makeNote(repo, body: "a")
        _ = try await rec.reconcile()
        try index.setWindowGeometry(WindowGeometry(x: 1, y: 1, width: 1, height: 1), for: n.document.metadata.id)
        try index.bind(to: sb.root.appendingPathComponent("other"))
        #expect(try index.noteCount() == 0)
        #expect(try index.windowGeometry(for: n.document.metadata.id) == nil)
    }
}
