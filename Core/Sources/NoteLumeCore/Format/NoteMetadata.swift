import Foundation

/// Portable note metadata stored in YAML frontmatter (requirements §3).
public struct NoteMetadata: Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var id: UUID
    public var title: String?
    public var labels: [String]
    public var color: String?
    public var textColor: String?
    public var opacity: Double?
    public var reminder: Date?
    public var sticky: Bool
    public var markdown: Bool
    public var created: Date
    public var updated: Date

    public init(
        schema: Int = NoteMetadata.currentSchema,
        id: UUID = UUID(),
        title: String? = nil,
        labels: [String] = [],
        color: String? = nil,
        textColor: String? = nil,
        opacity: Double? = nil,
        reminder: Date? = nil,
        sticky: Bool = false,
        markdown: Bool = true,
        created: Date = Date(),
        updated: Date = Date()
    ) {
        self.schema = schema
        self.id = id
        self.title = title
        self.labels = labels
        self.color = color
        self.textColor = textColor
        self.opacity = opacity
        self.reminder = reminder
        self.sticky = sticky
        self.markdown = markdown
        self.created = created
        self.updated = updated
    }
}

/// Problems found while reading a note. None of these discard data: the
/// offending values stay in the file untouched unless the user changes them.
public enum NoteIssue: Equatable, Sendable, Hashable, Codable {
    case missingFrontmatter
    case unterminatedFrontmatter
    case invalidYAML(String)
    case malformedField(name: String, detail: String)
    case idMismatch(filename: UUID, frontmatter: UUID)
    case unsupportedSchema(Int)

    public var message: String {
        switch self {
        case .missingFrontmatter:
            return "This note has no metadata block. It can be initialized without changing its content."
        case .unterminatedFrontmatter:
            return "The metadata block starts with --- but is never closed. The file was left unchanged."
        case .invalidYAML(let detail):
            return "The metadata block is not valid YAML (\(detail)). The original file was preserved."
        case .malformedField(let name, let detail):
            return "Metadata field “\(name)” is invalid (\(detail)) and was ignored; the stored value is preserved."
        case .idMismatch(let filename, let fm):
            return "Filename ID \(filename.uuidString) differs from metadata ID \(fm.uuidString). The filename is authoritative."
        case .unsupportedSchema(let v):
            return "Note uses metadata schema \(v), which is newer than this app understands. Its metadata is read-only."
        }
    }

    /// Issues that must block metadata writes to avoid damaging the file.
    public var blocksMetadataWrites: Bool {
        switch self {
        case .unterminatedFrontmatter, .invalidYAML, .unsupportedSchema: return true
        default: return false
        }
    }
}

enum ISO8601 {
    // Formatters are not Sendable; create per call (cheap relative to disk IO).
    static func parse(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.string(from: date)
    }
}
