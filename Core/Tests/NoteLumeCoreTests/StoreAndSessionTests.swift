import Foundation
import Testing
@testable import NoteLumeCore

func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func makeStore(_ sb: Sandbox) throws -> NoteStore {
    try NoteStore(notesDirectory: sb.notes, supportDirectory: sb.support, missingGrace: 0)
}

@Suite struct StoreTests {
    @Test(arguments: [false, true])
    func creationTextColorIsStoredPerNote(sticky: Bool) async throws {
        let sandbox = try Sandbox()
        let store = try makeStore(sandbox)
        let existing = try await store.create(body: "Existing", textColor: "#123456")
        let note = try await store.create(
            sticky: sticky, color: "#F5D76E", textColor: "#345678")
        let reopened = try await store.load(note.document.metadata.id)
        #expect(reopened.document.metadata.textColor == "#345678")
        #expect(reopened.document.metadata.color == "#F5D76E")
        #expect(reopened.document.metadata.sticky == sticky)
        #expect(try store.index.summary(id: note.document.metadata.id)?.textColor == "#345678")
        let automatic = try await store.create()
        #expect(automatic.document.metadata.textColor == nil)
        let unchanged = try await store.load(existing.document.metadata.id)
        #expect(unchanged.document.metadata.textColor == "#123456")
    }

    @Test func creationModeIsStoredPerNote() async throws {
        let sandbox = try Sandbox()
        let store = try makeStore(sandbox)
        let live = try await store.create(body: "Live")
        let source = try await store.create(body: "Source", markdown: false)
        #expect(live.document.metadata.markdown)
        #expect(!source.document.metadata.markdown)
        let reopened = NoteDocument(text: try sandbox.readRaw(source.document.metadata.id), filenameID: source.document.metadata.id)
        #expect(!reopened.metadata.markdown)
        #expect(try sandbox.readRaw(live.document.metadata.id).contains("markdown: true\n"))
    }

    @Test func createWritesFileImmediatelyAndIndexesIt() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let note = try await store.create(body: "# Quick\n", labels: ["inbox", " inbox ", ""])
        let id = note.document.metadata.id
        #expect(FileManager.default.fileExists(atPath: sb.url(id).path))
        #expect(try sb.readRaw(id).contains("- inbox"))
        let hits = try store.index.search(SearchQuery(text: "quick"))
        #expect(hits.map(\.note.id) == [id])
        #expect(hits[0].note.labels == ["inbox"])   // normalized & de-duplicated
    }

    @Test func mediaImagesAreNoteScopedAndRemovedOnPermanentDelete() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let note = try await store.create(body: "image")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let path = try await store.storeMediaImage(png, for: note.document.metadata.id)!
        #expect(path.hasPrefix("media/\(note.document.metadata.id.uuidString.lowercased())_"))
        #expect(path.hasSuffix(".png"))
        #expect(try await store.storeMediaImage(Data("not an image".utf8), for: note.document.metadata.id) == nil)

        try await store.trash(note.document.metadata.id)
        try await store.deletePermanently(note.document.metadata.id)
        #expect(!FileManager.default.fileExists(atPath: sb.notes.appendingPathComponent(path).path))
    }

    @Test func externalEditsAreDetectedAndEmitted() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let note = try await store.create(body: "one")
        await store.reconcile()
        var events = await store.events().makeAsyncIterator()

        var edited = note.document
        edited.body = "two"; edited.touch(now: Date().addingTimeInterval(10))
        try sb.writeRaw(edited.serialize(), id: edited.metadata.id)
        await store.reconcile()

        guard case .notesChanged(let updated, _, let external)? = await events.next() else { Issue.record("no event"); return }
        #expect(updated == [note.document.metadata.id])
        #expect(external)
    }

    @Test func labelRenameAndDeleteRewriteFiles() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let a = try await store.create(body: "a", labels: ["work", "x"])
        let b = try await store.create(body: "b", labels: ["work"])
        let c = try await store.create(body: "c", labels: ["home"])

        let r = try await store.renameLabel("work", to: "job 💼")
        #expect(Set(r.changed) == [a.document.metadata.id, b.document.metadata.id])
        #expect(try store.index.search(SearchQuery(labels: ["job 💼"])).count == 2)
        #expect(try store.index.search(SearchQuery(labels: ["work"])).isEmpty)
        #expect(try sb.readRaw(a.document.metadata.id).contains("job 💼"))

        // Renaming onto an existing label merges without duplicates.
        _ = try await store.renameLabel("x", to: "job 💼")
        #expect(try store.index.summary(id: a.document.metadata.id)?.labels == ["job 💼"])

        let d = try await store.deleteLabel("home")
        #expect(d.changed == [c.document.metadata.id])
        #expect(try store.index.summary(id: c.document.metadata.id)?.labels == [])
        // Bodies and unknown metadata untouched.
        #expect(try sb.readRaw(c.document.metadata.id).hasSuffix("---\nc"))
    }

    @Test func trashRemovesFromIndexAndRestoreBringsItBack() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let n = try await store.create(body: "# Doomed")
        let id = n.document.metadata.id
        try await store.trash(id)
        #expect(try store.index.search(SearchQuery()).isEmpty)
        #expect(try await store.trashedNotes().map(\.id) == [id])
        try await store.restore(id)
        #expect(try store.index.search(SearchQuery()).map(\.note.id) == [id])
    }

    @Test func cloudConflictCopiesAreSurfacedAndResolvable() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let n = try await store.create(body: "original")
        let id = n.document.metadata.id
        var other = n.document; other.body = "from the other mac"; other.touch()
        let copyURL = sb.notes.appendingPathComponent("\(id.uuidString.lowercased()) 2.md")
        try other.serialize().write(to: copyURL, atomically: true, encoding: .utf8)
        await store.reconcile()

        let copies = try await store.conflictCopies()
        #expect(copies.count == 1)
        // Conflict copies never show up as normal notes.
        #expect(try store.index.search(SearchQuery()).count == 1)

        try await store.resolve(copies[0], .keepBoth)
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        let all = try store.index.search(SearchQuery())
        #expect(all.count == 2)
        #expect(all.contains { $0.note.labels.contains("conflict") })
        #expect(try sb.readRaw(id).hasSuffix("original"))
    }

    @Test func useCopyReplacesOriginalButKeepsHistory() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let n = try await store.create(body: "original")
        let id = n.document.metadata.id
        var other = n.document; other.body = "winner"; other.touch()
        try other.serialize().write(to: sb.notes.appendingPathComponent("\(id.uuidString.lowercased()) (conflicted copy).md"), atomically: true, encoding: .utf8)
        await store.reconcile()
        try await store.resolve(try await store.conflictCopies()[0], .useCopy)
        #expect(try sb.readRaw(id).hasSuffix("winner"))
        let history = store.backups.versions(for: id)
        let texts = try history.map { String(data: try store.backups.data(for: $0), encoding: .utf8) ?? "" }
        #expect(texts.contains { $0.hasSuffix("original") })
    }

    @Test func importLeavesSourceFileUntouched() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let src = sb.notes.appendingPathComponent("shopping list.md")
        try "- milk\n- eggs\n".write(to: src, atomically: true, encoding: .utf8)
        await store.reconcile()
        #expect(await store.unrecognizedFiles.map(\.lastPathComponent) == ["shopping list.md"])
        let imported = try await store.importFile(at: src)
        #expect(imported.document.body == "- milk\n- eggs\n")
        #expect(try String(contentsOf: src, encoding: .utf8) == "- milk\n- eggs\n")
    }

    @Test func unavailableDirectoryReportsAndPreservesIndex() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        _ = try await store.create(body: "x")
        var events = await store.events().makeAsyncIterator()
        try FileManager.default.moveItem(at: sb.notes, to: sb.root.appendingPathComponent("away"))
        await store.reconcile()
        guard case .availability(.unavailable)? = await events.next() else { Issue.record("expected unavailable"); return }
        #expect(try store.index.noteCount() == 1)
    }
}

@MainActor
@Suite struct SessionTests {
    func open(_ store: NoteStore, body: String = "start") async throws -> (NoteEditSession, LoadedNote) {
        let loaded = try await store.create(body: body)
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .milliseconds(30), draftDelay: .milliseconds(5))
        return (s, loaded)
    }

    @Test func autosavesAfterDebounce() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let (s, n) = try await open(store)
        s.setBody("typed")
        #expect(s.state == .dirty)
        #expect(await waitUntil { s.state == .clean })
        #expect(try sb.readRaw(n.document.metadata.id).hasSuffix("typed"))
        #expect(store.recovery.draft(for: s.noteID) == nil)     // draft cleared after save
    }

    @Test func rapidEditsCoalesceAndLastWins() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let (s, n) = try await open(store)
        for i in 0..<20 { s.setBody("v\(i)") }
        await s.flush()
        #expect(s.state == .clean)
        #expect(try sb.readRaw(n.document.metadata.id).hasSuffix("v19"))
    }

    @Test func flushSavesImmediatelyWithoutWaitingForDebounce() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "start")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .seconds(60))
        s.setBody("closing now")
        await s.flush()
        #expect(try sb.readRaw(s.noteID).hasSuffix("closing now"))
    }

    @Test func draftExistsWhileDirtyForCrashRecovery() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "start")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("unsaved work")
        #expect(await waitUntil { store.recovery.draft(for: s.noteID) != nil })
        // "Crash": session vanishes without saving. File still has the old text…
        #expect(try sb.readRaw(s.noteID).hasSuffix("start"))
        // …but the draft is offered back on next launch.
        let candidates = await store.recoveryCandidates()
        #expect(candidates.count == 1)
        #expect(candidates[0].draft.text.hasSuffix("unsaved work"))
        #expect(!candidates[0].diskChangedSinceBase)

        let fresh = NoteEditSession(loaded: try await store.load(s.noteID), store: store, autosaveDelay: .milliseconds(20), draftDelay: .milliseconds(5))
        await fresh.applyRecoveredDraft(candidates[0].draft)
        #expect(await waitUntil { fresh.state == .clean })
        #expect(try sb.readRaw(s.noteID).hasSuffix("unsaved work"))
    }

    @Test func recoveryNeverOverwritesFileChangedSinceDraft() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "start")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("local unsaved")
        #expect(await waitUntil { store.recovery.draft(for: s.noteID) != nil })

        var external = loaded.document; external.body = "changed meanwhile"; external.touch(now: Date().addingTimeInterval(9))
        try sb.writeRaw(external.serialize(), id: s.noteID)

        let c = await store.recoveryCandidates()
        #expect(c.first?.diskChangedSinceBase == true)
        let fresh = NoteEditSession(loaded: try await store.load(s.noteID), store: store, autosaveDelay: .milliseconds(10), draftDelay: .milliseconds(5))
        await fresh.applyRecoveredDraft(c[0].draft)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fresh.state == .conflict)
        #expect(try sb.readRaw(s.noteID).hasSuffix("changed meanwhile"))
    }

    @Test func externalChangeAdoptedWhenClean() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let (s, n) = try await open(store)
        var ext = n.document; ext.body = "edited elsewhere"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        let rev = s.revision
        await s.diskDidChange()
        #expect(s.document.body == "edited elsewhere")
        #expect(s.revision == rev + 1)
        #expect(s.state == .clean)
    }

    @Test func externalChangeWhileDirtyEntersConflictWithoutOverwriting() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "base")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("my edit")
        var ext = loaded.document; ext.body = "their edit"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        await s.diskDidChange()
        #expect(s.state == .conflict)
        await s.flush()   // even an explicit flush must not clobber
        #expect(try sb.readRaw(s.noteID).hasSuffix("their edit"))
        #expect(s.document.body == "my edit")
    }

    @Test func saveRaceDetectedWithoutPriorEvent() async throws {
        // Disk changes and the autosave fires before any file event is seen.
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "base")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .milliseconds(20), draftDelay: .milliseconds(5))
        var ext = loaded.document; ext.body = "sneaky"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        s.setBody("mine")
        #expect(await waitUntil { s.state == .conflict })
        #expect(try sb.readRaw(s.noteID).hasSuffix("sneaky"))
    }

    @Test func resolveKeepMineSavesLocalAndArchivesDisk() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "base")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("mine")
        var ext = loaded.document; ext.body = "theirs"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        await s.diskDidChange()
        await s.resolveKeepingMine()
        #expect(s.state == .clean)
        #expect(try sb.readRaw(s.noteID).hasSuffix("mine"))
        let archived = try store.backups.versions(for: s.noteID).map { String(data: try store.backups.data(for: $0), encoding: .utf8) ?? "" }
        #expect(archived.contains { $0.hasSuffix("theirs") })
    }

    @Test func resolveTakeDiskArchivesLocalEdits() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "base")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("mine")
        var ext = loaded.document; ext.body = "theirs"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        await s.diskDidChange()
        s.resolveTakingDisk()
        #expect(s.state == .clean)
        #expect(s.document.body == "theirs")
        let archived = try store.backups.versions(for: s.noteID).map { String(data: try store.backups.data(for: $0), encoding: .utf8) ?? "" }
        #expect(archived.contains { $0.hasSuffix("mine") })
    }

    @Test func resolveKeepBothCreatesSeparateNote() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let loaded = try await store.create(body: "base")
        let s = NoteEditSession(loaded: loaded, store: store, autosaveDelay: .seconds(60), draftDelay: .milliseconds(5))
        s.setBody("mine")
        var ext = loaded.document; ext.body = "theirs"; ext.touch(now: Date().addingTimeInterval(5))
        try sb.writeRaw(ext.serialize(), id: s.noteID)
        await s.diskDidChange()
        let newID = try #require(try await s.resolveKeepingBoth())
        #expect(newID != s.noteID)
        #expect(try sb.readRaw(newID).hasSuffix("mine"))
        #expect(try sb.readRaw(s.noteID).hasSuffix("theirs"))
        #expect(s.state == .clean)
    }

    @Test func deletionWhileOpenCanBeUndoneByRecreating() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let (s, _) = try await open(store, body: "precious")
        try FileManager.default.removeItem(at: sb.url(s.noteID))
        s.setBody("precious plus more")
        await s.flush()
        #expect(s.state == .deletedOnDisk)
        #expect(!FileManager.default.fileExists(atPath: sb.url(s.noteID).path))
        await s.recreate()
        #expect(s.state == .clean)
        #expect(try sb.readRaw(s.noteID).hasSuffix("precious plus more"))
    }

    @Test func metadataEditsPersistAndKeepUnknownFields() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let id = UUID()
        try sb.writeRaw("---\nschema: 1\nid: \"\(id.uuidString.lowercased())\"\nx-owner: \"ana\"\nsticky: false\n---\n\nbody\n", id: id)
        await store.reconcile()
        let s = NoteEditSession(loaded: try await store.load(id), store: store, autosaveDelay: .milliseconds(10), draftDelay: .milliseconds(5))
        s.updateMetadata { $0.sticky = true; $0.labels = ["a b"]; $0.color = "#FF0000" }
        await s.flush()
        let raw = try sb.readRaw(id)
        #expect(raw.contains("x-owner: \"ana\""))
        #expect(raw.contains("sticky: true"))
        #expect(raw.contains("- a b"))
        #expect(raw.hasSuffix("---\n\nbody\n"))
        #expect(try store.index.summary(id: id)?.sticky == true)
    }

    @Test func initializingMissingMetadataKeepsBodyIntact() async throws {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let id = UUID()
        try sb.writeRaw("# plain note\n\nno frontmatter\n", id: id)
        await store.reconcile()
        let s = NoteEditSession(loaded: try await store.load(id), store: store, autosaveDelay: .milliseconds(10), draftDelay: .milliseconds(5))
        #expect(s.document.issues == [.missingFrontmatter])
        s.initializeMetadata()
        await s.flush()
        let raw = try sb.readRaw(id)
        #expect(raw.hasPrefix("---\nschema: 1\n"))
        #expect(raw.hasSuffix("---\n# plain note\n\nno frontmatter\n"))
    }
}
