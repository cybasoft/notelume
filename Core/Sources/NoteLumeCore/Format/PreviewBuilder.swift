import Foundation

enum PreviewBuilder {
    /// Short plain-text preview for cards: skips the line used as the title,
    /// drops list/heading markers, collapses whitespace.
    static func preview(body: String, hasExplicitTitle: Bool, limit: Int = 240) -> String {
        var skippedTitleLine = hasExplicitTitle
        var parts: [String] = []
        var length = 0
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !skippedTitleLine { skippedTitleLine = true; continue }
            if line.hasPrefix("```") || line.hasPrefix("---") { continue }
            let cleaned = TitleDeriver.title(fromBody: line)
            guard cleaned != "Untitled" else { continue }
            parts.append(cleaned)
            length += cleaned.count + 1
            if length >= limit { break }
        }
        let text = parts.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
