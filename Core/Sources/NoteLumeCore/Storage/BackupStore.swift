import Foundation

/// Local-only version history (requirements §11). Lives outside the notes
/// directory and outside the SQLite index, so losing either never loses history
/// and cloud sync never replicates it.
public final class BackupStore: @unchecked Sendable {
    public enum Reason: String, Sendable { case edit, external, delete, conflict, recovery }

    public struct Version: Sendable, Identifiable, Equatable {
        public var id: String { url.lastPathComponent }
        public var noteID: UUID
        public var date: Date
        public var reason: Reason
        public var url: URL
    }

    public struct Retention: Sendable {
        public var maxVersionsPerNote = 100
        public var maxAge: TimeInterval = 90 * 24 * 3600
        public var minKept = 10
        /// Edit snapshots closer together than this are skipped.
        public var editInterval: TimeInterval = 120
        public init() {}
    }

    private let root: URL
    private let retention: Retention
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(root: URL, retention: Retention = Retention()) {
        self.root = root
        self.retention = retention
    }

    @discardableResult
    public func snapshot(id: UUID, data: Data, reason: Reason, now: Date = Date()) -> Version? {
        lock.lock(); defer { lock.unlock() }
        let dir = folder(for: id)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = listLocked(id: id)
            let hash = String(FileVersion.hash(of: data).prefix(12))

            if let newest = existing.last {
                if newest.url.lastPathComponent.contains(hash) { return newest }   // identical content
                if reason == .edit, newest.reason == .edit, now.timeIntervalSince(newest.date) < retention.editInterval {
                    return nil
                }
            }
            let name = "\(Self.stamp(now))-\(reason.rawValue)-\(hash).md"
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            pruneLocked(id: id, now: now)
            return Version(noteID: id, date: now, reason: reason, url: url)
        } catch {
            return nil  // Backups are best-effort and must never block a save.
        }
    }

    public func versions(for id: UUID) -> [Version] {
        lock.lock(); defer { lock.unlock() }
        return listLocked(id: id).reversed()
    }

    public func data(for version: Version) throws -> Data { try Data(contentsOf: version.url) }

    /// IDs that have history, e.g. for finding notes deleted outside the app.
    public func noteIDsWithHistory() -> [UUID] {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    // MARK: Private

    private func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }

    /// Oldest → newest.
    private func listLocked(id: UUID) -> [Version] {
        let dir = folder(for: id)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        return names.compactMap { name in
            // <stamp>-<reason>-<hash>.md — none of the parts contain "-".
            let parts = name.dropLast(3).split(separator: "-").map(String.init)
            guard parts.count == 3, let date = Self.parseStamp(parts[0]), let reason = Reason(rawValue: parts[1]) else { return nil }
            return Version(noteID: id, date: date, reason: reason, url: dir.appendingPathComponent(name))
        }
    }

    private func pruneLocked(id: UUID, now: Date) {
        let all = listLocked(id: id)
        var removable: [Version] = []
        if all.count > retention.maxVersionsPerNote {
            removable += all.prefix(all.count - retention.maxVersionsPerNote)
        }
        let protectedTail = Set(all.suffix(retention.minKept).map(\.url))
        removable += all.filter { now.timeIntervalSince($0.date) > retention.maxAge && !protectedTail.contains($0.url) }
        for v in Set(removable.map(\.url)) { try? fm.removeItem(at: v) }
    }

    // Stamps sort lexicographically: 20261011T182030123Z
    private static func stamp(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian)
        var cal = c; cal.timeZone = TimeZone(identifier: "UTC")!
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
        return String(format: "%04d%02d%02dT%02d%02d%02d%03dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!, (p.nanosecond ?? 0) / 1_000_000)
    }

    private static func parseStamp(_ s: String) -> Date? {
        guard s.count == 19, s.hasSuffix("Z"), s.dropFirst(8).first == "T" else { return nil }
        let n = Array(s.dropLast())
        func i(_ a: Int, _ b: Int) -> Int? { Int(String(n[a..<b])) }
        guard let y = i(0, 4), let mo = i(4, 6), let d = i(6, 8), let h = i(9, 11), let mi = i(11, 13), let se = i(13, 15), let ms = i(15, 18) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: se)) else { return nil }
        return base.addingTimeInterval(Double(ms) / 1000)
    }
}
