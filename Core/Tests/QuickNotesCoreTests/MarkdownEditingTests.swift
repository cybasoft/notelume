import Foundation
import Testing
@testable import NoteLumeCore

@Suite struct MarkdownEditingTests {
    func apply(_ e: TextEdit, to s: String) -> (String, NSRange) {
        ((s as NSString).replacingCharacters(in: e.range, with: e.replacement), e.selection)
    }

    @Test func continuesBullets() {
        let s = "- one"
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: 5, length: 0))!
        let (t, sel) = apply(e, to: s)
        #expect(t == "- one\n- ")
        #expect(sel == NSRange(location: 8, length: 0))
    }

    @Test func continuesOrderedAndIncrements() {
        let e = MarkdownEditing.continueList(in: "9. nine", selection: NSRange(location: 7, length: 0))!
        #expect(apply(e, to: "9. nine").0 == "9. nine\n10. ")
        let p = MarkdownEditing.continueList(in: "2) b", selection: NSRange(location: 4, length: 0))!
        #expect(apply(p, to: "2) b").0 == "2) b\n3) ")
    }

    @Test func continuesCheckboxesAsUnchecked() {
        let s = "- [x] done"
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: 10, length: 0))!
        #expect(apply(e, to: s).0 == "- [x] done\n- [ ] ")
    }

    @Test func keepsIndentation() {
        let s = "a\n  - nested"
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: 12, length: 0))!
        #expect(apply(e, to: s).0 == "a\n  - nested\n  - ")
    }

    @Test func emptyItemEndsList() {
        let s = "- one\n- "
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: 8, length: 0))!
        let (t, sel) = apply(e, to: s)
        #expect(t == "- one\n")
        #expect(sel == NSRange(location: 6, length: 0))
        let box = "- [ ] "
        #expect(apply(MarkdownEditing.continueList(in: box, selection: NSRange(location: 6, length: 0))!, to: box).0 == "")
    }

    @Test func plainLinesFallBackToDefaultReturn() {
        #expect(MarkdownEditing.continueList(in: "hello", selection: NSRange(location: 5, length: 0)) == nil)
        #expect(MarkdownEditing.continueList(in: "-nospace", selection: NSRange(location: 8, length: 0)) == nil)
        #expect(MarkdownEditing.continueList(in: "- item", selection: NSRange(location: 1, length: 0)) == nil)  // caret inside marker
        #expect(MarkdownEditing.continueList(in: "- item", selection: NSRange(location: 2, length: 3)) == nil)  // has selection
    }

    @Test func splitsItemAtCaret() {
        let s = "- ab"
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: 3, length: 0))!
        #expect(apply(e, to: s).0 == "- a\n- b")
    }

    @Test func unicodeListContent() {
        let s = "- café 😀"
        let len = (s as NSString).length
        let e = MarkdownEditing.continueList(in: s, selection: NSRange(location: len, length: 0))!
        #expect(apply(e, to: s).0 == s + "\n- ")
    }

    @Test func wrapToggle() {
        // wrap
        var e = MarkdownEditing.toggleWrap(in: "hello world", selection: NSRange(location: 6, length: 5), marker: "**")
        #expect(apply(e, to: "hello world").0 == "hello **world**")
        #expect(e.selection == NSRange(location: 8, length: 5))
        // unwrap when markers outside selection
        e = MarkdownEditing.toggleWrap(in: "hello **world**", selection: NSRange(location: 8, length: 5), marker: "**")
        #expect(apply(e, to: "hello **world**").0 == "hello world")
        // unwrap when selection includes markers
        e = MarkdownEditing.toggleWrap(in: "hello **world**", selection: NSRange(location: 6, length: 9), marker: "**")
        #expect(apply(e, to: "hello **world**").0 == "hello world")
        // empty selection inserts a pair with caret inside
        e = MarkdownEditing.toggleWrap(in: "x", selection: NSRange(location: 1, length: 0), marker: "*")
        #expect(apply(e, to: "x").0 == "x**")
        #expect(e.selection == NSRange(location: 2, length: 0))
    }

    @Test func indentAndOutdentListLinesOnly() {
        let s = "- a\n- b"
        let e = MarkdownEditing.indent(in: s, selection: NSRange(location: 0, length: 7), outdent: false)!
        #expect(apply(e, to: s).0 == "  - a\n  - b")
        let back = MarkdownEditing.indent(in: "  - a\n  - b", selection: NSRange(location: 0, length: 11), outdent: true)!
        #expect(apply(back, to: "  - a\n  - b").0 == "- a\n- b")
        #expect(MarkdownEditing.indent(in: "plain text", selection: NSRange(location: 3, length: 0), outdent: false) == nil)
        #expect(MarkdownEditing.indent(in: "- a", selection: NSRange(location: 1, length: 0), outdent: true) == nil)
    }
}
