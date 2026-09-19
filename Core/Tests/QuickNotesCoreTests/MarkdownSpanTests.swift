import Foundation
import Testing
@testable import NoteLumeCore

@Suite struct MarkdownSpanTests {
    func text(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }
    func find(_ spans: [MarkdownSpan], _ pred: (MarkdownSpan.Kind) -> Bool) -> [MarkdownSpan] { spans.filter { pred($0.kind) } }

    @Test func inlineStyles() {
        let s = "plain **bold** and *it* and ~~gone~~ and `code`"
        let spans = MarkdownAnalyzer.spans(in: s)
        let strong = find(spans) { $0 == .strong }.first!
        #expect(text(s, strong.range) == "**bold**")
        #expect(strong.syntax.map { text(s, $0) } == ["**", "**"])
        let em = find(spans) { $0 == .emphasis }.first!
        #expect(text(s, em.range) == "*it*")
        let st = find(spans) { $0 == .strikethrough }.first!
        #expect(text(s, st.range) == "~~gone~~")
        let code = find(spans) { $0 == .inlineCode }.first!
        #expect(text(s, code.range) == "`code`")
        #expect(code.syntax.map { text(s, $0) } == ["`", "`"])
    }

    @Test func headingsAndMarkers() {
        let s = "# One\n\n### Three ###\n\nbody"
        let spans = find(MarkdownAnalyzer.spans(in: s)) { if case .heading = $0 { true } else { false } }
        #expect(spans.count == 2)
        #expect(spans[0].kind == .heading(level: 1))
        #expect(text(s, spans[0].syntax[0]) == "# ")
        #expect(spans[1].kind == .heading(level: 3))
        #expect(text(s, spans[1].syntax[0]) == "### ")
    }

    @Test func linkSyntaxHidesBracketsAndURL() {
        let s = "see [the docs](https://example.com/x) now"
        let link = find(MarkdownAnalyzer.spans(in: s)) { if case .link = $0 { true } else { false } }.first!
        #expect(text(s, link.range) == "[the docs](https://example.com/x)")
        #expect(link.syntax.map { text(s, $0) } == ["[", "](https://example.com/x)"])
        #expect(link.kind == .link(destination: "https://example.com/x"))
    }

    @Test func checkboxesAndListMarkers() {
        let s = "- [ ] todo\n- [x] done\n1. first\n- plain"
        let spans = MarkdownAnalyzer.spans(in: s)
        let boxes = find(spans) { if case .checkbox = $0 { true } else { false } }
        #expect(boxes.map { $0.kind } == [.checkbox(checked: false), .checkbox(checked: true)])
        #expect(boxes.map { text(s, $0.range) } == ["[ ]", "[x]"])
        let markers = find(spans) { $0 == .listMarker }.map { text(s, $0.range) }
        #expect(markers == ["-", "-", "1.", "-"])
    }

    @Test func toggleCheckboxRewritesOnlyTheMarker() {
        let s = "- [ ] a\n- [x] b\n"
        let boxes = find(MarkdownAnalyzer.spans(in: s)) { if case .checkbox = $0 { true } else { false } }
        let once = MarkdownAnalyzer.togglingCheckbox(in: s, at: boxes[0].range.location)
        #expect(once == "- [x] a\n- [x] b\n")
        let twice = MarkdownAnalyzer.togglingCheckbox(in: once!, at: boxes[1].range.location)
        #expect(twice == "- [x] a\n- [ ] b\n")
        #expect(MarkdownAnalyzer.togglingCheckbox(in: s, at: 0) == nil)
    }

    @Test func codeBlocksAndFences() {
        let s = "```swift\nlet x = 1\n```\n\nafter"
        let block = find(MarkdownAnalyzer.spans(in: s)) { if case .codeBlock = $0 { true } else { false } }.first!
        #expect(block.kind == .codeBlock(language: "swift"))
        #expect(block.syntax.map { text(s, $0) } == ["```swift", "```"])
    }

    @Test func blockQuoteMarkers() {
        let s = "> quoted\n> more\n\nafter"
        let q = find(MarkdownAnalyzer.spans(in: s)) { $0 == .blockQuote }.first!
        #expect(q.syntax.map { text(s, $0) } == ["> ", "> "])
    }

    @Test func tables() {
        let s = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n"
        let spans = MarkdownAnalyzer.spans(in: s)
        #expect(find(spans) { $0 == .tableHeader }.count == 1)
        #expect(find(spans) { $0 == .tableRow }.count == 2)
    }

    @Test func offsetsAreUTF16CorrectWithEmojiAndAccents() {
        let s = "é😀 **bold** ünï\n\n# Ünï 🎉"
        let spans = MarkdownAnalyzer.spans(in: s)
        let strong = find(spans) { $0 == .strong }.first!
        #expect(text(s, strong.range) == "**bold**")
        let h = find(spans) { if case .heading = $0 { true } else { false } }.first!
        #expect(text(s, h.range) == "# Ünï 🎉")
    }

    @Test func crlfLineEndings() {
        let s = "# Title\r\n\r\n**b** text\r\n"
        let strong = find(MarkdownAnalyzer.spans(in: s)) { $0 == .strong }.first!
        #expect(text(s, strong.range) == "**b**")
    }

    @Test func emptyAndUnsupportedSyntaxDoNotCrash() {
        #expect(MarkdownAnalyzer.spans(in: "").isEmpty)
        _ = MarkdownAnalyzer.spans(in: "<div>html</div>\n\n[^1]: footnote\n\n$$x^2$$\n\n{{ template }}")
        _ = MarkdownAnalyzer.spans(in: String(repeating: "**", count: 5000))
    }
}
