import Foundation
import Yams

/// Reads frontmatter with a real YAML parser and writes it back by editing only
/// the lines that changed, so unknown keys, comments, key order and unrelated
/// formatting survive (requirements §2, §4).
enum MetadataCodec {
    struct Decoded { var metadata: NoteMetadata; var issues: [NoteIssue] }

    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Decode

    static func decode(yaml: String, fallback: inout NoteMetadata, filenameID: UUID) throws -> Decoded {
        var meta = fallback
        var issues: [NoteIssue] = []

        guard let root = try Yams.compose(yaml: yaml) else {
            return Decoded(metadata: meta, issues: [])  // empty block
        }
        guard case .mapping(let mapping) = root else {
            throw DecodeError(description: "frontmatter must be a key/value mapping")
        }

        var fields: [String: Node] = [:]
        for (k, v) in mapping {
            if let key = k.scalar?.string, fields[key] == nil { fields[key] = v }
        }

        func bad(_ name: String, _ detail: String) { issues.append(.malformedField(name: name, detail: detail)) }

        func string(_ name: String) -> String? {
            guard let node = fields[name] else { return nil }
            guard let s = node.scalar?.string else { bad(name, "expected text"); return nil }
            return s
        }

        // schema: absent means a legacy / hand-written note (v0), upgraded on its next edit.
        meta.schema = 0
        if let node = fields["schema"] {
            if let v = node.int {
                meta.schema = v
                if v > NoteMetadata.currentSchema { issues.append(.unsupportedSchema(v)) }
            } else { bad("schema", "expected an integer") }
        }

        // id — the filename is authoritative
        if let s = string("id") {
            if let id = UUID(uuidString: s) {
                if id != filenameID { issues.append(.idMismatch(filename: filenameID, frontmatter: id)) }
            } else { bad("id", "not a UUID") }
        }
        meta.id = filenameID

        if let s = string("title") {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            meta.title = t.isEmpty ? nil : t
        }

        if let node = fields["labels"] {
            switch node {
            case .sequence(let seq):
                var labels: [String] = []
                for item in seq {
                    if let s = item.scalar?.string { labels.append(s) } else { bad("labels", "entries must be text") }
                }
                meta.labels = LabelNormalizer.normalize(labels)
            case .scalar(let sc):
                meta.labels = LabelNormalizer.normalize([sc.string])  // lenient: `labels: work`
            default:
                bad("labels", "expected a list")
            }
        }

        for name in ["color", "textColor"] {
            guard let s = string(name) else { continue }
            if HexColor.isValid(s) {
                if name == "color" { meta.color = s } else { meta.textColor = s }
            } else { bad(name, "expected #RRGGBB or #RRGGBBAA") }
        }

        if let node = fields["opacity"] {
            if let d = node.float ?? node.int.map(Double.init), (0...1).contains(d) {
                meta.opacity = d
            } else { bad("opacity", "expected a number between 0 and 1") }
        }

        if let s = string("reminder") {
            if let d = ISO8601.parse(s) { meta.reminder = d } else {
                bad("reminder", "expected ISO 8601 with a timezone, e.g. 2026-10-15T13:00:00Z")
            }
        }

        if let node = fields["sticky"] {
            if let b = node.bool { meta.sticky = b } else { bad("sticky", "expected true or false") }
        }

        if let node = fields["markdown"] {
            if let enabled = node.bool { meta.markdown = enabled } else { bad("markdown", "expected true or false") }
        }

        for name in ["created", "updated"] {
            guard let s = string(name) else { continue }
            if let d = ISO8601.parse(s) {
                if name == "created" { meta.created = d } else { meta.updated = d }
            } else { bad(name, "expected ISO 8601 timestamp") }
        }

        fallback = meta
        return Decoded(metadata: meta, issues: issues)
    }

    // MARK: Encode

    /// A frontmatter value we know how to write.
    private enum Value: Equatable {
        case scalar(String)      // already rendered YAML scalar
        case list([String])      // rendered list items (without "- ")

        func lines(key: String) -> [String] {
            switch self {
            case .scalar(let s): return ["\(key): \(s)"]
            case .list(let items): return items.isEmpty ? ["\(key): []"] : ["\(key):"] + items.map { "- \($0)" }
            }
        }
    }

    private static let keyOrder = ["schema", "id", "title", "labels", "color", "textColor",
                                   "opacity", "reminder", "sticky", "markdown", "created", "updated"]

    private static func values(_ m: NoteMetadata) -> [String: Value] {
        var v: [String: Value] = [:]
        v["schema"] = .scalar(String(m.schema))
        v["id"] = .scalar(quote(m.id.uuidString.lowercased()))
        if let t = m.title { v["title"] = .scalar(quote(t)) }
        if !m.labels.isEmpty { v["labels"] = .list(m.labels.map(plainOrQuoted)) }
        if let c = m.color { v["color"] = .scalar(quote(c)) }
        if let c = m.textColor { v["textColor"] = .scalar(quote(c)) }
        if let o = m.opacity { v["opacity"] = .scalar(String(o)) }
        if let r = m.reminder { v["reminder"] = .scalar(quote(ISO8601.format(r))) }
        v["sticky"] = .scalar(m.sticky ? "true" : "false")
        v["markdown"] = .scalar(m.markdown ? "true" : "false")
        v["created"] = .scalar(quote(ISO8601.format(m.created)))
        v["updated"] = .scalar(quote(ISO8601.format(m.updated)))
        return v
    }

    /// A complete new block.
    static func fresh(_ m: NoteMetadata) -> String {
        let v = values(m)
        let lines = keyOrder.compactMap { v[$0]?.lines(key: $0) }.flatMap { $0 }
        return (["---"] + lines + ["---"]).joined(separator: "\n") + "\n"
    }

    /// Applies the difference between `old` and `new` to an existing block,
    /// leaving every other line exactly as it was.
    static func update(block: String, from old: NoteMetadata, to new: NoteMetadata) -> String {
        let eol = block.contains("\r\n") ? "\r\n" : "\n"
        let endsWithEOL = block.last?.isNewline ?? false
        var lines = block.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if endsWithEOL { lines.removeLast() }  // trailing empty element from final terminator

        let oldValues = values(old), newValues = values(new)

        for key in keyOrder where oldValues[key] != newValues[key] {
            let replacement = newValues[key]?.lines(key: key)
            // Closing delimiter is the last line; search only the YAML region.
            if let range = extent(of: key, in: lines) {
                lines.replaceSubrange(range, with: replacement ?? [])
            } else if let replacement {
                lines.insert(contentsOf: replacement, at: max(lines.count - 1, 1))
            }
        }
        return lines.joined(separator: eol) + (endsWithEOL ? eol : "")
    }

    /// Line range occupied by top-level `key` (its line plus indented continuation / list lines).
    private static func extent(of key: String, in lines: [String]) -> Range<Int>? {
        guard lines.count >= 2 else { return nil }
        let last = lines.count - 1  // closing delimiter
        for i in 1..<last {
            guard let rest = valueText(afterKey: key, in: lines[i]) else { continue }
            let emptyValue = rest.trimmingCharacters(in: .whitespaces).isEmpty
            var end = i + 1
            while end < last {
                let l = lines[end]
                let indented = l.first == " " || l.first == "\t"
                let dashItem = emptyValue && (l.hasPrefix("- ") || l == "-")
                if indented || dashItem { end += 1 } else { break }
            }
            return i..<end
        }
        return nil
    }

    private static func valueText(afterKey key: String, in line: String) -> Substring? {
        guard let first = line.first, first != " ", first != "\t", first != "#" else { return nil }
        for prefix in ["\(key):", "\"\(key)\":", "'\(key)':"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { return rest }
        }
        return nil
    }

    // MARK: YAML scalar rendering

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Plain scalars read nicely (`- backend`), but anything YAML could
    /// reinterpret (`yes`, `123`, `a: b`, `#tag`) is quoted.
    static func plainOrQuoted(_ s: String) -> String {
        guard !s.isEmpty, s == s.trimmingCharacters(in: .whitespaces) else { return quote(s) }
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || " ._/+-".contains($0) }
        guard safe, let f = s.first, f.isLetter || f.isNumber else { return quote(s) }
        let resolved = Resolver.default.resolveTag(of: Node.scalar(.init(s, .implicit, .any)))
        return resolved == .str ? s : quote(s)
    }
}

enum HexColor {
    static func isValid(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let hex = s.dropFirst()
        return (hex.count == 6 || hex.count == 8) && hex.allSatisfy(\.isHexDigit)
    }
}

public enum LabelNormalizer {
    public struct TagExtraction: Equatable, Sendable {
        public var text: String
        public var labels: [String]
    }

    /// Trims, drops empties and de-duplicates (case-sensitively, first wins) while keeping order.
    /// Spaces, punctuation and non-ASCII characters are all permitted.
    public static func normalize(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in labels {
            let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            if !l.isEmpty, seen.insert(l).inserted { out.append(l) }
        }
        return out
    }

    /// Removes prose hashtags and returns unique labels, preserving first-seen spelling.
    public static func extractingHashtags(from text: String) -> TagExtraction {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "#([\\p{L}\\p{N}_-]+)") else {
            return TagExtraction(text: text, labels: [])
        }
        let spans = MarkdownAnalyzer.spans(in: text)
        let protected = spans.compactMap { span -> NSRange? in
            switch span.kind {
            case .codeBlock: CodeHighlighter.codeRange(in: text, span: span)
            case .inlineCode: span.range
            default: nil
            }
        }
        var labels: [String] = []
        var seen = Set<String>()
        var removals: [NSRange] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  match.numberOfRanges > 1 else { continue }
            let label = ns.substring(with: match.range(at: 1)).precomposedStringWithCanonicalMapping
            if seen.insert(label.lowercased()).inserted { labels.append(label) }
            var removal = match.range
            if removal.location > 0, [0x20, 0x09].contains(ns.character(at: removal.location - 1)) {
                removal.location -= 1
                removal.length += 1
            } else if NSMaxRange(removal) < ns.length, [0x20, 0x09].contains(ns.character(at: NSMaxRange(removal))) {
                removal.length += 1
            }
            removals.append(removal)
        }
        let mutable = NSMutableString(string: text)
        for range in removals.reversed() { mutable.deleteCharacters(in: range) }
        return TagExtraction(text: mutable as String, labels: labels)
    }
}
