import Foundation

/// Lightweight, index-backed view of a note for lists, cards and menus.
public struct NoteSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var labels: [String]
    public var color: String?
    public var textColor: String?
    public var opacity: Double?
    public var reminder: Date?
    public var sticky: Bool
    public var created: Date
    public var updated: Date
    public var preview: String
    public var issues: [NoteIssue]
    /// False while a cloud file has not finished downloading.
    public var isDownloaded: Bool
}

public struct SearchHit: Identifiable, Equatable, Sendable {
    public var id: UUID { note.id }
    public var note: NoteSummary
    /// Body excerpt with matches wrapped in `SearchHit.highlightStart/End`.
    public var snippet: String?

    public static let highlightStart = "\u{E000}"
    public static let highlightEnd = "\u{E001}"
}

public enum ReminderFilter: String, Sendable, CaseIterable {
    case any, hasReminder, overdue, upcoming, noReminder
}

public enum SearchSort: String, Sendable, CaseIterable {
    case relevance
    case updated
    case created
    case title
}

public struct SearchQuery: Equatable, Sendable {
    public var text: String = ""
    public var labels: Set<String> = []
    /// `true`: note must carry every selected label. `false`: any of them.
    public var matchAllLabels: Bool = true
    public var reminder: ReminderFilter = .any
    public var sticky: Bool?
    public var limit: Int = 500
    public var sort: SearchSort = .relevance

    public init(text: String = "", labels: Set<String> = [], matchAllLabels: Bool = true,
                reminder: ReminderFilter = .any, sticky: Bool? = nil, limit: Int = 500,
                sort: SearchSort = .relevance) {
        self.text = text
        self.labels = labels
        self.matchAllLabels = matchAllLabels
        self.reminder = reminder
        self.sticky = sticky
        self.limit = limit
        self.sort = sort
    }

    /// FTS5 MATCH expression from free text: every word becomes a quoted prefix
    /// term, so user input can never be interpreted as FTS syntax.
    static func ftsPattern(from text: String) -> String? {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber { current.append(ch) } else if !current.isEmpty { tokens.append(current); current = "" }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

public struct LabelCount: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var count: Int
}

// MARK: - Device-local state

public struct WindowGeometry: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var isOpen: Bool
    public var alwaysOnTop: Bool?

    public init(x: Double, y: Double, width: Double, height: Double, isOpen: Bool = true, alwaysOnTop: Bool? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.isOpen = isOpen; self.alwaysOnTop = alwaysOnTop
    }
}

public enum ReminderDelivery: String, Sendable {
    case scheduled, delivered, dismissed
}

public struct ReminderRecord: Equatable, Sendable {
    public var noteID: UUID
    /// The reminder date this record is for. A changed date is a new revision.
    public var fireDate: Date
    public var state: ReminderDelivery
}
