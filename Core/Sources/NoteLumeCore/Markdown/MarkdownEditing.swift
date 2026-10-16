import Foundation

/// A single replacement the editor applies to its text.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    /// Selection after the edit has been applied.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// Pure text-editing behaviours for the Markdown editor (list continuation,
/// emphasis toggling, indentation). They only ever return replacements; nothing
/// here normalises or reformats the rest of the document.
public enum MarkdownEditing {
    public enum SlashCommand: String, CaseIterable, Sendable {
        case code
        case checklist
        case heading
        case divider
        case today
        case image

        public var title: String {
            switch self {
            case .code: "Code block"
            case .checklist: "Checklist"
            case .heading: "Heading"
            case .divider: "Divider"
            case .today: "Today's date"
            case .image: "Image…"
            }
        }
    }

    struct ListPrefix {
        var indent: String
        var marker: String  // "-", "*", "+", "3."
        var checkbox: Bool
        var length: Int  // UTF-16 length of the whole prefix including trailing space
    }

    static func listPrefix(of line: String) -> ListPrefix? {
        let chars = Array(line.utf16)
        var i = 0
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        let indent = String(utf16CodeUnits: Array(chars[0..<i]), count: i)
        let markerStart = i
        if i < chars.count, [0x2D, 0x2A, 0x2B].contains(chars[i]) {
            i += 1
        } else {
            while i < chars.count, chars[i] >= 0x30, chars[i] <= 0x39 { i += 1 }
            guard i > markerStart, i < chars.count, chars[i] == 0x2E || chars[i] == 0x29 else {
                return nil
            }
            i += 1
        }
        guard i < chars.count, chars[i] == 0x20 else { return nil }
        let marker = String(utf16CodeUnits: Array(chars[markerStart..<i]), count: i - markerStart)
        i += 1
        // Optional task checkbox: "[ ]", "[x]" or "[X]", followed by a space or end of line.
        var checkbox = false
        if i + 2 < chars.count, chars[i] == 0x5B, [0x20, 0x78, 0x58].contains(chars[i + 1]),
            chars[i + 2] == 0x5D,
            i + 3 == chars.count || chars[i + 3] == 0x20
        {
            checkbox = true
            i += min(4, chars.count - i)
        }
        return ListPrefix(indent: indent, marker: marker, checkbox: checkbox, length: i)
    }

    private static func nextMarker(_ marker: String) -> String {
        guard let last = marker.last, last == "." || last == ")", let n = Int(marker.dropLast())
        else { return marker }
        return "\(n + 1)\(last)"
    }

    public static func slashCommands(matching query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return SlashCommand.allCases }
        return SlashCommand.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    public static func searchMatches(in text: String, query: String) -> [NSRange] {
        let ns = text as NSString
        let needle = query as NSString
        guard needle.length > 0 else { return [] }
        var matches: [NSRange] = []
        var location = 0
        while location <= ns.length - needle.length {
            let found = ns.range(
                of: query, options: .caseInsensitive,
                range: NSRange(location: location, length: ns.length - location))
            guard found.location != NSNotFound else { break }
            matches.append(found)
            location = NSMaxRange(found)
        }
        return matches
    }

    public static func imageDestination(in source: String) -> String? {
        let markdown = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard markdown.hasPrefix("!["), markdown.hasSuffix(")"),
            let delimiter = markdown.range(of: "](")
        else { return nil }
        let destination = markdown[delimiter.upperBound..<markdown.index(before: markdown.endIndex)]
        guard !destination.isEmpty else { return nil }
        return String(destination.split(separator: " ", maxSplits: 1).first ?? "")
    }

    public static func selection(_ selection: NSRange, touches range: NSRange) -> Bool {
        if selection.length == 0 { return NSLocationInRange(selection.location, range) }
        return NSIntersectionRange(selection, range).length > 0
    }

    public static func completeCodeFence(in text: String, selection: NSRange, typed: String) -> TextEdit? {
        let ns = text as NSString
        guard typed == "`", selection.length == 0,
            selection.location >= 2, selection.location <= ns.length
        else { return nil }
        let line = ns.lineRange(for: selection)
        let prefix = ns.substring(with: NSRange(
            location: line.location, length: selection.location - line.location))
        let indent = String(prefix.prefix { $0 == " " })
        guard indent.count <= 3, prefix == indent + "``" else { return nil }
        let suffix = ns.substring(with: NSRange(
            location: selection.location, length: NSMaxRange(line) - selection.location))
            .trimmingCharacters(in: .newlines)
        guard suffix.isEmpty || suffix == "`" else { return nil }
        let insideCode = MarkdownAnalyzer.spans(in: text).contains { span in
            guard case .codeBlock = span.kind else { return false }
            return span.range.location < line.location && selection.location <= NSMaxRange(span.range)
        }
        guard !insideCode else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        return TextEdit(
            range: NSRange(location: selection.location, length: (suffix as NSString).length),
            replacement: "`" + newline + indent + newline + indent + "```",
            selection: NSRange(
                location: selection.location + 1 + (newline as NSString).length + indent.utf16.count,
                length: 0))
    }

    public static func autoPair(in text: String, selection: NSRange, typed: String) -> TextEdit? {
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
        guard let closing = pairs[typed], (typed as NSString).length == 1 else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length, NSMaxRange(selection) <= ns.length else {
            return nil
        }
        if selection.length > 0 {
            let selected = ns.substring(with: selection)
            let openingLength = (typed as NSString).length
            return TextEdit(
                range: selection, replacement: typed + selected + closing,
                selection: NSRange(
                    location: selection.location + openingLength, length: selection.length))
        }
        return TextEdit(
            range: selection, replacement: typed + closing,
            selection: NSRange(location: selection.location + (typed as NSString).length, length: 0)
        )
    }

    public static func closingCharacterSelection(in text: String, selection: NSRange, typed: String)
        -> NSRange?
    {
        let closers = [")", "]", "}", "\"", "'", "`"]
        let ns = text as NSString
        guard closers.contains(typed), (typed as NSString).length == 1, selection.length == 0,
            selection.location < ns.length,
            ns.substring(with: NSRange(location: selection.location, length: 1)) == typed
        else { return nil }
        return NSRange(location: selection.location + 1, length: 0)
    }

    /// Return pressed with the caret in a list item: continue the list, or end it if the item is empty.
    public static func continueList(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        var contentRange = lineRange
        while contentRange.length > 0,
            let c = Optional(ns.character(at: NSMaxRange(contentRange) - 1)), c == 0x0A || c == 0x0D
        { contentRange.length -= 1 }
        let line = ns.substring(with: contentRange)
        guard let prefix = listPrefix(of: line) else { return nil }
        let caretInLine = selection.location - contentRange.location
        guard caretInLine >= prefix.length else { return nil }  // caret inside the marker: plain newline

        let rest = (line as NSString).substring(from: prefix.length)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: Return removes the marker and ends the list.
            return TextEdit(
                range: contentRange, replacement: "",
                selection: NSRange(location: contentRange.location, length: 0))
        }
        let insertion =
            "\n" + prefix.indent + nextMarker(prefix.marker) + " " + (prefix.checkbox ? "[ ] " : "")
        return TextEdit(
            range: NSRange(location: selection.location, length: 0), replacement: insertion,
            selection: NSRange(
                location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// ⌘B / ⌘I style toggling. Unwraps when the selection is already wrapped.
    public static func toggleWrap(in text: String, selection: NSRange, marker: String) -> TextEdit {
        let ns = text as NSString
        let m = (marker as NSString).length
        let sel = NSRange(
            location: min(selection.location, ns.length),
            length: min(selection.length, ns.length - min(selection.location, ns.length)))

        if sel.length == 0 {
            return TextEdit(
                range: sel, replacement: marker + marker,
                selection: NSRange(location: sel.location + m, length: 0))
        }
        let selected = ns.substring(with: sel)
        // Selection includes the markers themselves.
        if selected.hasPrefix(marker), selected.hasSuffix(marker), sel.length >= 2 * m {
            let inner = (selected as NSString).substring(
                with: NSRange(location: m, length: sel.length - 2 * m))
            return TextEdit(
                range: sel, replacement: inner,
                selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        // Markers sit just outside the selection.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
            ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
            ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker
        {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return TextEdit(
                range: outer, replacement: selected,
                selection: NSRange(location: outer.location, length: sel.length))
        }
        return TextEdit(
            range: sel, replacement: marker + selected + marker,
            selection: NSRange(location: sel.location + m, length: sel.length))
    }

    /// Tab / Shift-Tab on list lines. Returns nil when the lines are not list items (default tab behaviour).
    public static func indent(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        let block = ns.lineRange(for: selection)
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        var changed = false
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isLast && line.isEmpty {
                out.append(line)
                continue
            }
            guard listPrefix(of: line) != nil else {
                out.append(line)
                continue
            }
            if outdent {
                if line.hasPrefix("  ") {
                    out.append(String(line.dropFirst(2)))
                    changed = true
                } else if line.hasPrefix("\t") {
                    out.append(String(line.dropFirst()))
                    changed = true
                } else if line.hasPrefix(" ") {
                    out.append(String(line.dropFirst()))
                    changed = true
                } else {
                    out.append(line)
                }
            } else {
                out.append("  " + line)
                changed = true
            }
        }
        guard changed else { return outdent ? nil : nil }
        let replacement = out.joined(separator: "\n")
        let delta = (replacement as NSString).length - block.length
        let newSel =
            selection.length == 0
            ? NSRange(
                location: max(block.location, selection.location + (outdent ? -min(2, -delta) : 2)),
                length: 0)
            : NSRange(location: block.location, length: block.length + delta)
        return TextEdit(range: block, replacement: replacement, selection: newSel)
    }

    /// Indents code lines by two spaces, or removes up to two leading spaces on each selected line.
    public static func indentCode(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let ns = text as NSString
        guard selection.location <= ns.length, NSMaxRange(selection) <= ns.length else {
            return nil
        }
        guard
            let block = MarkdownAnalyzer.spans(in: text).first(where: { span in
                guard case .codeBlock = span.kind,
                    let range = CodeHighlighter.codeRange(in: text, span: span)
                else { return false }
                return range.length > 0 && selection.location >= range.location
                    && NSMaxRange(selection) <= NSMaxRange(range)
            }), let codeRange = CodeHighlighter.codeRange(in: text, span: block)
        else { return nil }

        let lastOffset =
            selection.length == 0
            ? selection.location : max(selection.location, NSMaxRange(selection) - 1)
        var lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let lastLineStart = ns.lineRange(for: NSRange(location: lastOffset, length: 0)).location
        var operations: [(range: NSRange, replacement: String)] = []

        while lineStart <= lastLineStart, lineStart < NSMaxRange(codeRange) {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            if outdent {
                let limit = min(NSMaxRange(line), NSMaxRange(codeRange))
                var count = 0
                while lineStart + count < limit, count < 2,
                    ns.character(at: lineStart + count) == 0x20
                { count += 1 }
                if count == 0, lineStart < limit, ns.character(at: lineStart) == 0x09 { count = 1 }
                if count > 0 {
                    operations.append((NSRange(location: lineStart, length: count), ""))
                }
            } else {
                operations.append((NSRange(location: lineStart, length: 0), "  "))
            }
            let nextLine = NSMaxRange(line)
            guard nextLine > lineStart else { break }
            lineStart = nextLine
        }
        guard !operations.isEmpty else { return nil }

        let editStart = operations[0].range.location
        let lastLine = ns.lineRange(for: NSRange(location: lastLineStart, length: 0))
        let editEnd = min(NSMaxRange(lastLine), NSMaxRange(codeRange))
        let editRange = NSRange(location: editStart, length: editEnd - editStart)
        let mutable = NSMutableString(string: ns.substring(with: editRange))
        for operation in operations.reversed() {
            mutable.replaceCharacters(
                in: NSRange(
                    location: operation.range.location - editStart, length: operation.range.length),
                with: operation.replacement)
        }

        func adjustedOffset(_ offset: Int) -> Int {
            offset
                + operations.reduce(0) { delta, operation in
                    let affected =
                        operation.range.length == 0
                        ? operation.range.location <= offset
                        : NSMaxRange(operation.range) <= offset
                    return delta
                        + (affected
                            ? (operation.replacement as NSString).length - operation.range.length
                            : 0)
                }
        }
        let newLocation = adjustedOffset(selection.location)
        let newEnd = adjustedOffset(NSMaxRange(selection))
        return TextEdit(
            range: editRange, replacement: mutable as String,
            selection: NSRange(location: newLocation, length: newEnd - newLocation))
    }

    /// Moves the caret after a code fence, inserting a blank line when necessary.
    public static func escapeCodeBlock(
        in text: String, selection: NSRange, onlyAtLastLine: Bool = false
    ) -> TextEdit? {
        let ns = text as NSString
        guard selection.location <= ns.length,
            let span = MarkdownAnalyzer.spans(in: text).first(where: { span in
                guard case .codeBlock = span.kind,
                    let range = CodeHighlighter.codeRange(in: text, span: span)
                else { return false }
                return selection.location >= range.location
                    && selection.location <= NSMaxRange(range)
            }), span.syntax.count > 1
        else { return nil }

        guard let codeRange = CodeHighlighter.codeRange(in: text, span: span) else { return nil }
        if onlyAtLastLine {
            let currentLine = ns.lineRange(for: NSRange(location: selection.location, length: 0))
                .location
            let lastContentOffset = max(codeRange.location, NSMaxRange(codeRange) - 1)
            let lastLine = ns.lineRange(for: NSRange(location: lastContentOffset, length: 0))
                .location
            guard currentLine == lastLine else { return nil }
        }

        let fenceEnd = NSMaxRange(span.syntax[1])
        guard fenceEnd <= ns.length else { return nil }
        let suffix = ns.substring(from: fenceEnd) as NSString
        var newlineCount = 0
        var suffixOffset = 0
        while suffixOffset < suffix.length {
            let character = suffix.character(at: suffixOffset)
            if character == 0x0D {
                newlineCount += 1
                suffixOffset +=
                    suffixOffset + 1 < suffix.length
                        && suffix.character(at: suffixOffset + 1) == 0x0A ? 2 : 1
            } else if character == 0x0A {
                newlineCount += 1
                suffixOffset += 1
            } else {
                break
            }
        }
        let missing = max(0, 2 - newlineCount)
        let separator = text.contains("\r\n") ? "\r\n" : "\n"
        let insertion = String(repeating: separator, count: missing)
        let caret = fenceEnd + suffixOffset + (insertion as NSString).length
        return TextEdit(
            range: NSRange(location: fenceEnd, length: 0), replacement: insertion,
            selection: NSRange(location: caret, length: 0))
    }
}
