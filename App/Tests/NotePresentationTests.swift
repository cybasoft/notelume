import Foundation
import NoteLumeCore
import Testing
@testable import NoteLume

@MainActor
@Suite struct NotePresentationTests {
    private func withFixture(_ body: (URL, NoteIndex) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await {
            let index = try NoteIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
            try await body(root, index)
        }()
    }

    @Test func existingInstallationsKeepSeparateWindows() async throws {
        try await withFixture { _, index in
            #expect(DeviceSettings(index: index).noteOpenMode == .windows)
        }
    }

    @Test func openingModePersistsInDeviceSettings() async throws {
        try await withFixture { _, index in
            let settings = DeviceSettings(index: index)
            settings.noteOpenMode = .library
            #expect(DeviceSettings(index: index).noteOpenMode == .library)
            settings.noteOpenMode = .windows
            #expect(DeviceSettings(index: index).noteOpenMode == .windows)
        }
    }

    @Test func unknownOpeningModeFallsBackToSeparateWindows() async throws {
        try await withFixture { _, index in
            try index.setSetting("noteOpenMode", "unknown")
            #expect(DeviceSettings(index: index).noteOpenMode == .windows)
        }
    }

    @Test func stickyNotesComeFirstWithoutChangingOrderWithinGroups() async throws {
        try await withFixture { root, index in
            let notes = root.appendingPathComponent("notes")
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            let repository = FileNoteRepository(directory: notes, backups: BackupStore(root: root.appendingPathComponent("backups")))
            for (title, sticky) in [("Alpha", false), ("Beta", true), ("Gamma", false), ("Omega", true)] {
                _ = try await repository.create(NoteDocument(metadata: NoteMetadata(title: title, sticky: sticky), body: title))
            }
            _ = try await Reconciler(repository: repository, index: index).reconcile()
            let hits = try index.search(SearchQuery(sort: .title))
            #expect(LibraryView.stickyFirst(hits).map(\.note.title) == ["Beta", "Omega", "Alpha", "Gamma"])
            #expect(LibraryView.stickyFirst([]).isEmpty)
            #expect(LibraryView.stickyFirst(hits.filter { !$0.note.sticky }) == hits.filter { !$0.note.sticky })
        }
    }
}