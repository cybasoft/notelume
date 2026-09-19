import Foundation

/// Splits a note file into its frontmatter block and body without
/// regular expressions and without altering either part's bytes.
enum FrontmatterSplitter {
    enum Result {
        /// File does not begin with a `---` line.
        case none
        /// Opening delimiter found but never closed.
        case unterminated
        /// `block` is everything up to and including the closing delimiter's
        /// line terminator; `yaml` is the text between the delimiters.
        case found(block: String, yaml: String, body: String)
    }

    static let bom = "\u{FEFF}"

    static func split(_ input: String) -> Result {
        var text = Substring(input)
        if text.hasPrefix(bom) { text = text.dropFirst() }

        guard let first = nextLine(in: text, from: text.startIndex), isOpening(first.content) else {
            return .none
        }
        var cursor = first.next
        let yamlStart = cursor
        while cursor < text.endIndex {
            guard let line = nextLine(in: text, from: cursor) else { break }
            if isClosing(line.content) {
                return .found(
                    block: String(text[text.startIndex..<line.next]),
                    yaml: String(text[yamlStart..<cursor]),
                    body: String(text[line.next...])
                )
            }
            cursor = line.next
        }
        return .unterminated
    }

    private struct Line { let content: Substring; let next: String.Index }

    private static func nextLine(in text: Substring, from start: String.Index) -> Line? {
        guard start < text.endIndex else { return nil }
        // Character-level search treats "\r\n" as a single newline.
        if let nl = text[start...].firstIndex(where: \.isNewline) {
            return Line(content: text[start..<nl], next: text.index(after: nl))
        }
        return Line(content: text[start...], next: text.endIndex)
    }

    private static func trimmed(_ s: Substring) -> Substring {
        var s = s
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return s
    }

    private static func isOpening(_ s: Substring) -> Bool { trimmed(s) == "---" }
    private static func isClosing(_ s: Substring) -> Bool { let t = trimmed(s); return t == "---" || t == "..." }
}
