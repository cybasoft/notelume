import Foundation
import Yams

/// A parsed note file: YAML frontmatter + Markdown body.
///
/// Guarantees (requirements §2, §4):
/// - `serialize()` of an unmodified document returns the original text byte-for-byte.
/// - Body-only edits never reformat the frontmatter, apart from the `updated` line.
/// - Unknown frontmatter keys, key order and malformed known values survive edits.
/// - A document with unreadable frontmatter keeps its original block verbatim.
public struct NoteDocument: Sendable {
    public var metadata: NoteMetadata
    public var body: String
    public private(set) var issues: [NoteIssue]
    public private(set) var hasFrontmatter: Bool

    /// Original frontmatter block text (delimiters included), if any.
    private var originalBlock: String?
    private var hadBOM: Bool
    /// Metadata as last read from / written to disk, used to find what changed.
    private var baseline: NoteMetadata

    public var canEditMetadata: Bool { !issues.contains(where: \.blocksMetadataWrites) }

    public var displayTitle: String {
        if let t = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return TitleDeriver.title(fromBody: body)
    }

    // MARK: Creating

    /// A brand-new note with full metadata.
    public init(metadata: NoteMetadata = NoteMetadata(), body: String = "") {
        self.metadata = metadata
        self.body = body
        self.issues = []
        self.hasFrontmatter = true
        self.originalBlock = nil
        self.hadBOM = false
        self.baseline = metadata
    }

    // MARK: Parsing

    /// Parses file contents. Never throws and never drops data.
    /// - Parameters:
    ///   - filenameID: UUID from the filename; authoritative identifier.
    ///   - fileDates: fallbacks for notes lacking `created`/`updated`.
    public init(text: String, filenameID: UUID, fileDates: (created: Date, modified: Date) = (Date(), Date())) {
        var fallback = NoteMetadata(id: filenameID, created: fileDates.created, updated: fileDates.modified)
        self.hadBOM = false
        self.issues = []

        switch FrontmatterSplitter.split(text) {
        case .none:
            self.body = text
            self.hasFrontmatter = false
            self.originalBlock = nil
            self.issues = [.missingFrontmatter]
            self.metadata = fallback
            self.baseline = fallback

        case .unterminated:
            // Treat the whole file as body but refuse metadata writes so the
            // block cannot be clobbered.
            self.body = text
            self.hasFrontmatter = false
            self.originalBlock = nil
            self.issues = [.unterminatedFrontmatter]
            self.metadata = fallback
            self.baseline = fallback

        case .found(let block, let yaml, let body):
            self.hadBOM = text.hasPrefix(FrontmatterSplitter.bom)
            self.body = body
            self.hasFrontmatter = true
            self.originalBlock = block
            do {
                let parsed = try MetadataCodec.decode(yaml: yaml, fallback: &fallback, filenameID: filenameID)
                self.metadata = parsed.metadata
                self.issues = parsed.issues
            } catch {
                self.metadata = fallback
                self.issues = [.invalidYAML(String(describing: error).prefix(200).description)]
            }
            self.baseline = self.metadata
        }
    }

    // MARK: Mutating

    /// Creates a metadata block for a note that has none, without touching the body.
    public mutating func initializeMetadata(now: Date = Date()) {
        guard !hasFrontmatter, canEditMetadata else { return }
        hasFrontmatter = true
        originalBlock = nil
        issues.removeAll { $0 == .missingFrontmatter }
        metadata.updated = now
    }

    /// Marks the note as modified now, upgrading older metadata schemas in the
    /// same write. Opening a note never rewrites it; only a real edit does.
    public mutating func touch(now: Date = Date()) {
        migrateSchemaIfNeeded()
        metadata.updated = now
    }

    /// Schema migrations (documented in docs/FORMAT.md). Each step is additive
    /// and idempotent; unknown fields are never touched. Newer schemas are never downgraded.
    public mutating func migrateSchemaIfNeeded() {
        guard hasFrontmatter, canEditMetadata, metadata.schema < NoteMetadata.currentSchema else { return }
        // v0 → v1: notes written by hand or by other tools lack `schema`; stamp it.
        metadata.schema = NoteMetadata.currentSchema
    }

    /// Resolves an ID mismatch in favour of the filename.
    public mutating func adoptFilenameID(_ id: UUID) {
        metadata.id = id
        issues.removeAll { if case .idMismatch = $0 { return true } else { return false } }
    }

    // MARK: Serializing

    /// Full file contents.
    public func serialize() -> String {
        let bom = hadBOM ? FrontmatterSplitter.bom : ""
        guard hasFrontmatter else { return body }
        return bom + (currentBlock() ?? "") + body
    }

    private func currentBlock() -> String? {
        guard canEditMetadata else { return originalBlock }
        guard let original = originalBlock else { return MetadataCodec.fresh(metadata) }
        return metadata == baseline ? original : MetadataCodec.update(block: original, from: baseline, to: metadata)
    }

    /// Records that the current state is what is on disk.
    public mutating func markSaved() {
        originalBlock = hasFrontmatter ? currentBlock() : nil
        baseline = metadata
    }

    /// After saving a snapshot of this document while edits continued, adopt the
    /// snapshot's on-disk formatting state without discarding the newer edits.
    public mutating func adoptSavedState(from saved: NoteDocument) {
        var saved = saved
        saved.markSaved()
        originalBlock = saved.originalBlock
        baseline = saved.baseline
        hasFrontmatter = saved.hasFrontmatter
        hadBOM = saved.hadBOM
    }

    /// True when `other` would serialize to the same file contents.
    public func hasSameContent(as other: NoteDocument) -> Bool { serialize() == other.serialize() }
}

// MARK: - Title derivation

enum TitleDeriver {
    static func title(fromBody body: String) -> String {
        for raw in body.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            line = stripBlockPrefix(line)
            for marker in ["**", "__", "~~", "`"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
            if !line.isEmpty { return String(line.prefix(200)) }
        }
        return "Untitled"
    }

    private static func stripBlockPrefix(_ line: String) -> String {
        var s = Substring(line)
        // Headings, quotes
        while let f = s.first, f == "#" || f == ">" { s = s.dropFirst() }
        s = s.drop(while: { $0 == " " })
        // Task / bullet markers
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "] where s.hasPrefix(marker) {
            s = s.dropFirst(marker.count)
            break
        }
        // Ordered list "12. "
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 10 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { s = rest.dropFirst(2) }
        }
        return String(s)
    }
}
