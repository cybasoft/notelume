import Foundation
import GRDB

/// What the index remembers about a file, used to detect external changes.
public struct IndexedFile: Equatable, Sendable {
    public var id: UUID
    public var modified: Date
    public var size: Int
    public var hash: String
    public var isDownloaded: Bool
    public var missingSince: Date?
}

/// Local SQLite database: full-text index, cached metadata and device-specific
/// state (requirements §1, §3). Everything in the note/search tables is derived
/// from the Markdown files and can be discarded and rebuilt at any time.
/// The database lives under Application Support and is never placed in the
/// synced notes directory.
public final class NoteIndex: Sendable {
    private let pool: DatabasePool
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            pool = try Self.open(databaseURL)
        } catch {
            // A damaged cache must never block access to notes. Keep the bad file
            // for inspection, start fresh, and let reconciliation repopulate it.
            Self.quarantine(databaseURL)
            pool = try Self.open(databaseURL)
        }
    }

    private static func open(_ url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(pool)
        _ = try pool.read { try $0.execute(sql: "SELECT count(*) FROM sqlite_master") }
        return pool
    }

    private static func quarantine(_ url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            try? fm.moveItem(at: src, to: dst)
        }
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("uuid", .text).notNull().unique()
                t.column("file_mtime", .double).notNull()
                t.column("file_size", .integer).notNull()
                t.column("content_hash", .text).notNull()
                t.column("title", .text).notNull()
                t.column("explicit_title", .boolean).notNull().defaults(to: false)
                t.column("labels", .text).notNull().defaults(to: "[]")
                t.column("color", .text)
                t.column("text_color", .text)
                t.column("opacity", .double)
                t.column("reminder", .double)
                t.column("sticky", .boolean).notNull().defaults(to: false)
                t.column("created", .double).notNull()
                t.column("updated", .double).notNull()
                t.column("preview", .text).notNull().defaults(to: "")
                t.column("issues", .text).notNull().defaults(to: "[]")
                t.column("downloaded", .boolean).notNull().defaults(to: true)
                t.column("missing_since", .double)
            }
            try db.create(index: "note_updated", on: "note", columns: ["updated"])
            try db.create(index: "note_reminder", on: "note", columns: ["reminder"])

            try db.create(table: "note_label") { t in
                t.column("note_rowid", .integer).notNull().references("note", column: "rowid", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.primaryKey(["note_rowid", "label"])
            }
            try db.create(index: "note_label_label", on: "note_label", columns: ["label"])

            try db.create(virtualTable: "note_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("title")
                t.column("labels")
                t.column("body")
            }

            try db.create(table: "conflict_copy") { t in
                t.primaryKey("path", .text)
                t.column("original_id", .text).notNull()
                t.column("modified", .double).notNull()
            }

            // Device-specific state: survives index rebuilds, never synced.
            try db.create(table: "window_geometry") { t in
                t.primaryKey("note_id", .text)
                t.column("json", .text).notNull()
            }
            try db.create(table: "device_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "reminder_state") { t in
                t.column("note_id", .text).notNull()
                t.column("fire_date", .double).notNull()
                t.column("state", .text).notNull()
                t.primaryKey(["note_id", "fire_date"])
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }

    // MARK: Binding & rebuilding

    /// Ties the cache to a notes directory. Switching directories discards the
    /// derived data (and per-note device state, which refers to other notes).
    public func bind(to directory: URL) throws {
        try pool.write { db in
            let current = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'notes_path'")
            if let current, current != directory.path {
                try Self.clearDerived(db)
                try db.execute(sql: "DELETE FROM window_geometry")
                try db.execute(sql: "DELETE FROM reminder_state")
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('notes_path', ?)", arguments: [directory.path])
        }
    }

    /// Drops all derived data. Notes on disk are untouched; run a reconcile afterwards.
    public func clearAllDerivedData() throws {
        try pool.write { try Self.clearDerived($0) }
    }

    private static func clearDerived(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM note_fts")
        try db.execute(sql: "DELETE FROM note_label")
        try db.execute(sql: "DELETE FROM note")
        try db.execute(sql: "DELETE FROM conflict_copy")
    }

    // MARK: Reconciliation support

    public func indexedFiles() throws -> [UUID: IndexedFile] {
        try pool.read { db in
            var out: [UUID: IndexedFile] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT uuid, file_mtime, file_size, content_hash, downloaded, missing_since FROM note") {
                guard let id = UUID(uuidString: row["uuid"]) else { continue }
                out[id] = IndexedFile(
                    id: id,
                    modified: Date(timeIntervalSince1970: row["file_mtime"]),
                    size: row["file_size"], hash: row["content_hash"],
                    isDownloaded: row["downloaded"],
                    missingSince: (row["missing_since"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
            return out
        }
    }

    /// Inserts or refreshes cached metadata and search text, in one transaction.
    public func upsert(_ notes: [LoadedNote]) throws {
        guard !notes.isEmpty else { return }
        try pool.write { db in
            for note in notes { try Self.write(note, in: db) }
        }
    }

    public func upsert(_ note: LoadedNote) throws { try upsert([note]) }

    private static func write(_ note: LoadedNote, in db: Database) throws {
        let doc = note.document
        let m = doc.metadata
        let labelsJSON = json(m.labels)
        let issuesJSON = json(doc.issues)
        let explicit = !(m.title?.isEmpty ?? true)
        let preview = PreviewBuilder.preview(body: doc.body, hasExplicitTitle: explicit)

        let uuid = m.id.uuidString.lowercased()
        try db.execute(sql: """
            INSERT INTO note (uuid, file_mtime, file_size, content_hash, title, explicit_title, labels, color, text_color,
                              opacity, reminder, sticky, created, updated, preview, issues, downloaded, missing_since)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,NULL)
            ON CONFLICT(uuid) DO UPDATE SET
                file_mtime=excluded.file_mtime, file_size=excluded.file_size, content_hash=excluded.content_hash,
                title=excluded.title, explicit_title=excluded.explicit_title, labels=excluded.labels,
                color=excluded.color, text_color=excluded.text_color, opacity=excluded.opacity,
                reminder=excluded.reminder, sticky=excluded.sticky, created=excluded.created,
                updated=excluded.updated, preview=excluded.preview, issues=excluded.issues,
                downloaded=1, missing_since=NULL
            """, arguments: [
                uuid, note.version.modified.timeIntervalSince1970, note.version.size, note.version.hash,
                doc.displayTitle, explicit, labelsJSON, m.color, m.textColor, m.opacity,
                m.reminder?.timeIntervalSince1970, m.sticky, m.created.timeIntervalSince1970,
                m.updated.timeIntervalSince1970, preview, issuesJSON,
            ])
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE uuid = ?", arguments: [uuid])!

        try db.execute(sql: "DELETE FROM note_label WHERE note_rowid = ?", arguments: [rowid])
        for label in m.labels {
            try db.execute(sql: "INSERT OR IGNORE INTO note_label(note_rowid, label) VALUES(?,?)", arguments: [rowid, label])
        }
        try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO note_fts(rowid, title, labels, body) VALUES(?,?,?,?)",
                       arguments: [rowid, doc.displayTitle, m.labels.joined(separator: " "), doc.body])
    }

    /// Records that a file exists but its content is not yet available locally.
    public func markNotDownloaded(_ entry: NoteFileEntry) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE note SET downloaded = 0 WHERE uuid = ?", arguments: [entry.id.uuidString.lowercased()])
        }
    }

    /// Updates only change-detection fields when a file's mtime moved but its content did not.
    public func touchFile(id: UUID, modified: Date, size: Int) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE note SET file_mtime = ?, file_size = ?, missing_since = NULL, downloaded = 1 WHERE uuid = ?",
                           arguments: [modified.timeIntervalSince1970, size, id.uuidString.lowercased()])
        }
    }

    public func markMissing(_ ids: [UUID], since: Date) throws {
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE note SET missing_since = ? WHERE uuid = ? AND missing_since IS NULL",
                               arguments: [since.timeIntervalSince1970, id.uuidString.lowercased()])
            }
        }
    }

    /// Removes index rows (never files) for notes that stayed missing past the grace period.
    @discardableResult
    public func purgeMissing(olderThan cutoff: Date) throws -> [UUID] {
        try pool.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rowid, uuid FROM note WHERE missing_since IS NOT NULL AND missing_since < ?",
                                        arguments: [cutoff.timeIntervalSince1970])
            for row in rows {
                let rowid: Int64 = row["rowid"]
                try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM note WHERE rowid = ?", arguments: [rowid])
            }
            return rows.compactMap { UUID(uuidString: $0["uuid"]) }
        }
    }

    /// Removes one note's index rows immediately (used after an in-app trash).
    public func remove(id: UUID) throws {
        try pool.write { db in
            let uuid = id.uuidString.lowercased()
            if let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE uuid = ?", arguments: [uuid]) {
                try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM note WHERE rowid = ?", arguments: [rowid])
            }
        }
    }

    public func replaceConflictCopies(_ copies: [ConflictCopyEntry]) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM conflict_copy")
            for c in copies {
                try db.execute(sql: "INSERT INTO conflict_copy(path, original_id, modified) VALUES(?,?,?)",
                               arguments: [c.url.path, c.originalID.uuidString.lowercased(), c.modified.timeIntervalSince1970])
            }
        }
    }

    public func conflictCopies() throws -> [ConflictCopyEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT path, original_id, modified FROM conflict_copy ORDER BY modified DESC").compactMap { row in
                guard let id = UUID(uuidString: row["original_id"]) else { return nil }
                return ConflictCopyEntry(originalID: id, url: URL(fileURLWithPath: row["path"]),
                                         modified: Date(timeIntervalSince1970: row["modified"]))
            }
        }
    }

    public func noteCount(sticky: Bool? = nil) throws -> Int {
        try pool.read { db in
            if let sticky {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE missing_since IS NULL AND sticky = ?", arguments: [sticky]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE missing_since IS NULL") ?? 0
        }
    }

    // MARK: Queries

    public func summary(id: UUID) throws -> NoteSummary? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM note WHERE uuid = ?", arguments: [id.uuidString.lowercased()]).flatMap(Self.summary(from:))
        }
    }

    public func search(_ query: SearchQuery, now: Date = Date()) throws -> [SearchHit] {
        var conditions = ["n.missing_since IS NULL"]
        var args: [any DatabaseValueConvertible] = []
        let pattern = SearchQuery.ftsPattern(from: query.text)

        if let sticky = query.sticky { conditions.append("n.sticky = ?"); args.append(sticky) }

        switch query.reminder {
        case .any: break
        case .hasReminder: conditions.append("n.reminder IS NOT NULL")
        case .noReminder: conditions.append("n.reminder IS NULL")
        case .overdue: conditions.append("n.reminder IS NOT NULL AND n.reminder < ?"); args.append(now.timeIntervalSince1970)
        case .upcoming: conditions.append("n.reminder IS NOT NULL AND n.reminder >= ?"); args.append(now.timeIntervalSince1970)
        }

        if !query.labels.isEmpty {
            let labels = query.labels.sorted()
            let marks = Array(repeating: "?", count: labels.count).joined(separator: ",")
            var sub = "n.rowid IN (SELECT note_rowid FROM note_label WHERE label IN (\(marks)) GROUP BY note_rowid"
            if query.matchAllLabels { sub += " HAVING COUNT(DISTINCT label) = ?" }
            sub += ")"
            conditions.append(sub)
            args.append(contentsOf: labels)
            if query.matchAllLabels { args.append(labels.count) }
        }

        let sql: String
        if let pattern {
            conditions.append("note_fts MATCH ?")
            args.append(pattern)
            sql = """
                SELECT n.*, snippet(note_fts, 2, '\(SearchHit.highlightStart)', '\(SearchHit.highlightEnd)', '…', 14) AS snip
                FROM note n JOIN note_fts ON note_fts.rowid = n.rowid
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY bm25(note_fts, 10.0, 5.0, 1.0), n.updated DESC LIMIT ?
                """
        } else {
            let order: String
            switch query.sort {
            case .created: order = "n.created DESC, n.updated DESC, n.uuid ASC"
            case .title: order = "n.title COLLATE NOCASE ASC, n.updated DESC, n.uuid ASC"
            case .relevance, .updated: order = "n.updated DESC, n.uuid ASC"
            }
            sql = """
                SELECT n.*, NULL AS snip FROM note n
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(order) LIMIT ?
                """
        }
        args.append(query.limit)

        return try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)!).compactMap { row in
                guard let s = Self.summary(from: row) else { return nil }
                return SearchHit(note: s, snippet: row["snip"])
            }
        }
    }

    public func labelCounts() throws -> [LabelCount] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.label AS label, count(*) AS c FROM note_label l
                JOIN note n ON n.rowid = l.note_rowid WHERE n.missing_since IS NULL
                GROUP BY l.label ORDER BY l.label COLLATE NOCASE
                """).map { LabelCount(label: $0["label"], count: $0["c"]) }
        }
    }

    /// Notes with a reminder, soonest first. Used for the menubar and scheduler.
    public func reminderNotes() throws -> [NoteSummary] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM note WHERE reminder IS NOT NULL AND missing_since IS NULL ORDER BY reminder")
                .compactMap(Self.summary(from:))
        }
    }

    private static func summary(from row: Row) -> NoteSummary? {
        guard let id = UUID(uuidString: row["uuid"]) else { return nil }
        let labels: [String] = decode(row["labels"]) ?? []
        let issues: [NoteIssue] = decode(row["issues"]) ?? []
        return NoteSummary(
            id: id, title: row["title"], labels: labels,
            color: row["color"], textColor: row["text_color"], opacity: row["opacity"],
            reminder: (row["reminder"] as Double?).map(Date.init(timeIntervalSince1970:)),
            sticky: row["sticky"],
            created: Date(timeIntervalSince1970: row["created"]),
            updated: Date(timeIntervalSince1970: row["updated"]),
            preview: row["preview"], issues: issues, isDownloaded: row["downloaded"])
    }

    // MARK: Device-specific state

    public func windowGeometry(for id: UUID) throws -> WindowGeometry? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM window_geometry WHERE note_id = ?", arguments: [id.uuidString.lowercased()])
                .flatMap { Self.decode($0) }
        }
    }

    public func setWindowGeometry(_ g: WindowGeometry, for id: UUID) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO window_geometry(note_id, json) VALUES(?,?)",
                           arguments: [id.uuidString.lowercased(), Self.json(g)])
        }
    }

    public func openWindowNoteIDs() throws -> [UUID] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT note_id, json FROM window_geometry").compactMap { row in
                guard let g: WindowGeometry = Self.decode(row["json"]), g.isOpen else { return nil }
                return UUID(uuidString: row["note_id"])
            }
        }
    }

    public func setting(_ key: String) throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT value FROM device_setting WHERE key = ?", arguments: [key]) }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        try pool.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO device_setting(key, value) VALUES(?,?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM device_setting WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: Reminder bookkeeping (device-local)

    public func reminderRecords() throws -> [ReminderRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT note_id, fire_date, state FROM reminder_state").compactMap { row in
                guard let id = UUID(uuidString: row["note_id"]), let state = ReminderDelivery(rawValue: row["state"]) else { return nil }
                return ReminderRecord(noteID: id, fireDate: Date(timeIntervalSince1970: row["fire_date"]), state: state)
            }
        }
    }

    public func setReminderState(noteID: UUID, fireDate: Date, state: ReminderDelivery) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO reminder_state(note_id, fire_date, state) VALUES(?,?,?)",
                           arguments: [noteID.uuidString.lowercased(), fireDate.timeIntervalSince1970, state.rawValue])
        }
    }

    /// Forgets bookkeeping for revisions other than the note's current one.
    public func pruneReminderRecords(keeping current: [UUID: Date]) throws {
        try pool.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT note_id, fire_date FROM reminder_state") {
                let fire = Date(timeIntervalSince1970: row["fire_date"])
                guard let id = UUID(uuidString: row["note_id"]), current[id] == fire else {
                    try db.execute(sql: "DELETE FROM reminder_state WHERE note_id = ? AND fire_date = ?",
                                   arguments: [row["note_id"] as String, row["fire_date"] as Double])
                    continue
                }
            }
        }
    }

    // MARK: JSON helpers

    private static func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? String(data: enc.encode(value), encoding: .utf8)) ?? "[]"
    }

    private static func decode<T: Decodable>(_ string: String?) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
