import Foundation
import Markdown

/// A styled region of Markdown source, expressed in UTF-16 ranges so it can be
/// applied directly to an `NSTextStorage`.
///
/// The editor never rewrites the text to "render" Markdown. It keeps the raw
/// source as the single canonical document and only *decorates* it using these
/// spans, hiding `syntax` ranges when the caret is elsewhere. That is what makes
/// WYSIWYG and source mode edit the same content and preserve any syntax the
/// styler does not understand (requirements §4).
public struct MarkdownSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        case inlineCode
        case codeBlock(language: String?)
        case link(destination: String?)
        case image
        case blockQuote
        case listMarker
        case checkbox(checked: Bool)
        case tableHeader
        case tableRow
        case thematicBreak
    }

    public var kind: Kind
    public var range: NSRange
    /// Marker characters (`**`, `#`, `[`, …) that may be hidden while not being edited.
    public var syntax: [NSRange]

    public init(kind: Kind, range: NSRange, syntax: [NSRange] = []) {
        self.kind = kind
        self.range = range
        self.syntax = syntax
    }
}

public enum MarkdownAnalyzer {
    public static func spans(in text: String) -> [MarkdownSpan] {
        guard !text.isEmpty else { return [] }
        var collector = Collector(text: text)
        collector.visit(Document(parsing: text))
        // Outer spans first so inner styling is applied on top.
        return collector.spans.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
    }

    /// Toggles the checkbox whose marker starts at `utf16Offset`; returns the new text.
    public static func togglingCheckbox(in text: String, at utf16Offset: Int) -> String? {
        let ns = text as NSString
        guard utf16Offset >= 0, utf16Offset + 3 <= ns.length else { return nil }
        let marker = ns.substring(with: NSRange(location: utf16Offset, length: 3))
        let replacement: String
        switch marker {
        case "[ ]": replacement = "[x]"
        case "[x]", "[X]": replacement = "[ ]"
        default: return nil
        }
        return ns.replacingCharacters(in: NSRange(location: utf16Offset, length: 3), with: replacement)
    }

    // MARK: Offsets

    /// (line, UTF-8 column) → UTF-16 offset.
    struct OffsetMap {
        private var lineStarts: [Int] = [0]     // UTF-8 byte offsets
        private var utf16At: [Int32]            // UTF-8 byte offset → UTF-16 offset
        let utf8Count: Int

        init(_ text: String) {
            let bytes = Array(text.utf8)
            utf8Count = bytes.count
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x0A { lineStarts.append(i + 1) }
                else if b == 0x0D {
                    if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
                    lineStarts.append(i + 1)
                }
                i += 1
            }
            utf16At = [Int32](repeating: 0, count: bytes.count + 1)
            var byte = 0, unit: Int32 = 0
            for scalar in text.unicodeScalars {
                let n8 = UTF8.width(scalar)
                for k in 0..<n8 { utf16At[byte + k] = unit }   // continuation bytes map to the scalar start
                byte += n8
                unit += Int32(scalar.value > 0xFFFF ? 2 : 1)
            }
            utf16At[bytes.count] = unit
        }

        func offset(line: Int, column: Int) -> Int? {
            guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
            let byte = min(lineStarts[line - 1] + column - 1, utf8Count)
            return Int(utf16At[byte])
        }

        func range(_ r: SourceRange) -> NSRange? {
            guard let lo = offset(line: r.lowerBound.line, column: r.lowerBound.column),
                  let hi = offset(line: r.upperBound.line, column: r.upperBound.column), hi >= lo else { return nil }
            return NSRange(location: lo, length: hi - lo)
        }
    }

    // MARK: Walker

    private struct Collector: MarkupWalker {
        let ns: NSString
        let map: OffsetMap
        var spans: [MarkdownSpan] = []

        init(text: String) {
            ns = text as NSString
            map = OffsetMap(text)
        }

        private func nsRange(_ m: Markup) -> NSRange? {
            guard let r = m.range, let nr = map.range(r), NSMaxRange(nr) <= ns.length else { return nil }
            return nr
        }

        private func char(at i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }

        private func run(of c: Character, from start: Int, limit: Int) -> Int {
            var n = 0
            let u = c.utf16.first!
            while start + n < limit, char(at: start + n) == u { n += 1 }
            return n
        }

        mutating func visitHeading(_ heading: Heading) {
            if let r = nsRange(heading) {
                var syntax: [NSRange] = []
                let hashes = run(of: "#", from: r.location, limit: NSMaxRange(r))
                if hashes > 0 {   // ATX heading; setext headings have no leading marker
                    var end = r.location + hashes
                    while char(at: end) == 0x20 { end += 1 }
                    syntax.append(NSRange(location: r.location, length: end - r.location))
                }
                spans.append(.init(kind: .heading(level: heading.level), range: r, syntax: syntax))
            }
            descendInto(heading)
        }

        mutating func visitStrong(_ strong: Strong) {
            if let r = nsRange(strong), r.length >= 4 {
                spans.append(.init(kind: .strong, range: r, syntax: [
                    NSRange(location: r.location, length: 2),
                    NSRange(location: NSMaxRange(r) - 2, length: 2)]))
            }
            descendInto(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            if let r = nsRange(emphasis), r.length >= 2 {
                spans.append(.init(kind: .emphasis, range: r, syntax: [
                    NSRange(location: r.location, length: 1),
                    NSRange(location: NSMaxRange(r) - 1, length: 1)]))
            }
            descendInto(emphasis)
        }

        mutating func visitStrikethrough(_ s: Strikethrough) {
            if let r = nsRange(s) {
                let n = min(run(of: "~", from: r.location, limit: NSMaxRange(r)), 2)
                if n > 0, r.length >= 2 * n {
                    spans.append(.init(kind: .strikethrough, range: r, syntax: [
                        NSRange(location: r.location, length: n),
                        NSRange(location: NSMaxRange(r) - n, length: n)]))
                }
            }
            descendInto(s)
        }

        mutating func visitInlineCode(_ code: InlineCode) {
            if let r = nsRange(code) {
                let n = run(of: "`", from: r.location, limit: NSMaxRange(r))
                var syntax: [NSRange] = []
                if n > 0, r.length >= 2 * n {
                    syntax = [NSRange(location: r.location, length: n), NSRange(location: NSMaxRange(r) - n, length: n)]
                }
                spans.append(.init(kind: .inlineCode, range: r, syntax: syntax))
            }
        }

        mutating func visitLink(_ link: Link) {
            if let r = nsRange(link) {
                var syntax: [NSRange] = []
                if char(at: r.location) == 0x5B /* [ */ {
                    syntax.append(NSRange(location: r.location, length: 1))
                    if let last = link.children.reversed().compactMap({ nsRange($0) }).first {
                        let tail = NSMaxRange(last)
                        syntax.append(NSRange(location: tail, length: NSMaxRange(r) - tail))
                    }
                }
                spans.append(.init(kind: .link(destination: link.destination), range: r, syntax: syntax))
            }
            descendInto(link)
        }

        mutating func visitImage(_ image: Image) {
            if let r = nsRange(image) { spans.append(.init(kind: .image, range: r)) }
        }

        mutating func visitCodeBlock(_ block: CodeBlock) {
            if let r = nsRange(block) {
                var syntax: [NSRange] = []
                let fence = run(of: "`", from: r.location, limit: NSMaxRange(r))
                let tilde = run(of: "~", from: r.location, limit: NSMaxRange(r))
                if fence >= 3 || tilde >= 3 {
                    let text = ns.substring(with: r)
                    let lines = text.components(separatedBy: .newlines)
                    let firstLen = (lines.first ?? "").utf16.count
                    syntax.append(NSRange(location: r.location, length: firstLen))
                    if lines.count > 1, let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix(fence >= 3 ? "```" : "~~~") {
                        syntax.append(NSRange(location: NSMaxRange(r) - last.utf16.count, length: last.utf16.count))
                    }
                }
                spans.append(.init(kind: .codeBlock(language: block.language), range: r, syntax: syntax))
            }
        }

        mutating func visitBlockQuote(_ quote: BlockQuote) {
            if let r = nsRange(quote) {
                var syntax: [NSRange] = []
                var lineStart = r.location
                while lineStart < NSMaxRange(r) {
                    var i = lineStart
                    while char(at: i) == 0x20 { i += 1 }
                    if char(at: i) == 0x3E /* > */ {
                        var end = i + 1
                        if char(at: end) == 0x20 { end += 1 }
                        syntax.append(NSRange(location: i, length: end - i))
                    }
                    let lineEnd = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                    lineStart = NSMaxRange(lineEnd)
                    if lineEnd.length == 0 { break }
                }
                spans.append(.init(kind: .blockQuote, range: r, syntax: syntax))
            }
            descendInto(quote)
        }

        mutating func visitListItem(_ item: ListItem) {
            if let r = nsRange(item) {
                var i = r.location
                // bullet or "12." / "12)"
                let markerStart = i
                if let c = char(at: i), c == 0x2D || c == 0x2A || c == 0x2B { i += 1 }
                else {
                    while let c = char(at: i), c >= 0x30 && c <= 0x39 { i += 1 }
                    if i > markerStart, let c = char(at: i), c == 0x2E || c == 0x29 { i += 1 } else { i = markerStart }
                }
                if i > markerStart {
                    spans.append(.init(kind: .listMarker, range: NSRange(location: markerStart, length: i - markerStart)))
                    while char(at: i) == 0x20 { i += 1 }
                    if let box = item.checkbox, NSMaxRange(r) >= i + 3, char(at: i) == 0x5B {
                        spans.append(.init(kind: .checkbox(checked: box == .checked), range: NSRange(location: i, length: 3)))
                    }
                }
            }
            descendInto(item)
        }

        mutating func visitTable(_ table: Table) {
            if let r = nsRange(table.head) { spans.append(.init(kind: .tableHeader, range: r)) }
            for row in table.body.rows { if let r = nsRange(row) { spans.append(.init(kind: .tableRow, range: r)) } }
            descendInto(table)
        }

        mutating func visitThematicBreak(_ b: ThematicBreak) {
            if let r = nsRange(b) { spans.append(.init(kind: .thematicBreak, range: r)) }
        }
    }
}
