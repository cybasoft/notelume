import Foundation

/// Crash recovery for unsaved edits (requirements §11). The editor writes a draft
/// here shortly after each change; the draft is removed once the note is saved.
/// After a crash or forced quit the drafts that differ from disk are offered back.
public final class RecoveryStore: @unchecked Sendable {
    public struct Draft: Codable, Sendable, Equatable {
        public var noteID: UUID
        /// Hash of the disk version the edit was based on (nil for never-saved notes).
        public var baseHash: String?
        public var text: String
        public var savedAt: Date
    }

    private let root: URL
    private let lock = NSLock()

    public init(root: URL) { self.root = root }

    public func write(_ draft: Draft) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: url(draft.noteID), options: .atomic)
        } catch { /* best effort: autosave remains the primary path */ }
    }

    public func clear(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(id))
    }

    public func draft(for id: UUID) -> Draft? {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    }

    public func allDrafts() -> [Draft] {
        lock.lock(); defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
        }
    }

    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".json") }
}
