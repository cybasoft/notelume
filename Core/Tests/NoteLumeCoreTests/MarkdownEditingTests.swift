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
        let e = MarkdownEditing.continueList(
            in: "9. nine", selection: NSRange(location: 7, length: 0))!
        #expect(apply(e, to: "9. nine").0 == "9. nine\n10. ")
        let p = MarkdownEditing.continueList(
            in: "2) b", selection: NSRange(location: 4, length: 0))!
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
        #expect(
            apply(
                MarkdownEditing.continueList(in: box, selection: NSRange(location: 6, length: 0))!,
                to: box
            ).0 == "")
    }

    @Test func plainLinesFallBackToDefaultReturn() {
        #expect(
            MarkdownEditing.continueList(in: "hello", selection: NSRange(location: 5, length: 0))
                == nil)
        #expect(
            MarkdownEditing.continueList(in: "-nospace", selection: NSRange(location: 8, length: 0))
                == nil)
        #expect(
            MarkdownEditing.continueList(in: "- item", selection: NSRange(location: 1, length: 0))
                == nil)  // caret inside marker
        #expect(
            MarkdownEditing.continueList(in: "- item", selection: NSRange(location: 2, length: 3))
                == nil)  // has selection
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
        var e = MarkdownEditing.toggleWrap(
            in: "hello world", selection: NSRange(location: 6, length: 5), marker: "**")
        #expect(apply(e, to: "hello world").0 == "hello **world**")
        #expect(e.selection == NSRange(location: 8, length: 5))
        // unwrap when markers outside selection
        e = MarkdownEditing.toggleWrap(
            in: "hello **world**", selection: NSRange(location: 8, length: 5), marker: "**")
        #expect(apply(e, to: "hello **world**").0 == "hello world")
        // unwrap when selection includes markers
        e = MarkdownEditing.toggleWrap(
            in: "hello **world**", selection: NSRange(location: 6, length: 9), marker: "**")
        #expect(apply(e, to: "hello **world**").0 == "hello world")
        // empty selection inserts a pair with caret inside
        e = MarkdownEditing.toggleWrap(
            in: "x", selection: NSRange(location: 1, length: 0), marker: "*")
        #expect(apply(e, to: "x").0 == "x**")
        #expect(e.selection == NSRange(location: 2, length: 0))
    }

    @Test func indentAndOutdentListLinesOnly() {
        let s = "- a\n- b"
        let e = MarkdownEditing.indent(
            in: s, selection: NSRange(location: 0, length: 7), outdent: false)!
        #expect(apply(e, to: s).0 == "  - a\n  - b")
        let back = MarkdownEditing.indent(
            in: "  - a\n  - b", selection: NSRange(location: 0, length: 11), outdent: true)!
        #expect(apply(back, to: "  - a\n  - b").0 == "- a\n- b")
        #expect(
            MarkdownEditing.indent(
                in: "plain text", selection: NSRange(location: 3, length: 0), outdent: false) == nil
        )
        #expect(
            MarkdownEditing.indent(
                in: "- a", selection: NSRange(location: 1, length: 0), outdent: true) == nil)
    }

    @Test func indentAndOutdentCodeLines() {
        let text = "```swift\nlet a = 1\nprint(a)\n```"
        let ns = text as NSString
        let firstLine = ns.range(of: "let a").location
        let secondLineEnd = NSMaxRange(ns.range(of: "print(a)"))
        let selection = NSRange(location: firstLine, length: secondLineEnd - firstLine)
        let indented = MarkdownEditing.indentCode(in: text, selection: selection, outdent: false)!
        #expect(apply(indented, to: text).0 == "```swift\n  let a = 1\n  print(a)\n```")
        let indentedText = apply(indented, to: text).0
        let innerStart = (indentedText as NSString).range(of: "  let a").location
        let innerEnd = NSMaxRange((indentedText as NSString).range(of: "  print(a)"))
        let outdented = MarkdownEditing.indentCode(
            in: indentedText,
            selection: NSRange(location: innerStart, length: innerEnd - innerStart),
            outdent: true)!
        #expect(apply(outdented, to: indentedText).0 == text)
    }

    @Test func codeEscapeAddsBlankLineAndOnlyDownEscapesLastLine() {
        let text = "```swift\nlet a = 1\nprint(a)\n```"
        let ns = text as NSString
        let firstLine = ns.range(of: "let a").location
        let lastLine = ns.range(of: "print(a)").location
        #expect(
            MarkdownEditing.escapeCodeBlock(
                in: text, selection: NSRange(location: firstLine, length: 0), onlyAtLastLine: true)
                == nil)

        let escape = MarkdownEditing.escapeCodeBlock(
            in: text, selection: NSRange(location: lastLine, length: 0))!
        let (escaped, selection) = apply(escape, to: text)
        #expect(escaped == text + "\n\n")
        #expect(selection.location == (escaped as NSString).length)

        let alreadySeparated = text + "\n\nnext"
        let existing = MarkdownEditing.escapeCodeBlock(
            in: alreadySeparated,
            selection: NSRange(location: lastLine, length: 0),
            onlyAtLastLine: true)!
        #expect(apply(existing, to: alreadySeparated).0 == alreadySeparated)
        #expect(
            (alreadySeparated as NSString).substring(from: existing.selection.location) == "next")
    }

    @Test func automaticPairsAndClosingCharacterOverwrite() {
        let pair = MarkdownEditing.autoPair(
            in: "value", selection: NSRange(location: 5, length: 0), typed: "(")!
        #expect(apply(pair, to: "value").0 == "value()")
        #expect(pair.selection == NSRange(location: 6, length: 0))

        let quote = MarkdownEditing.autoPair(
            in: "word", selection: NSRange(location: 0, length: 4), typed: "\"")!
        #expect(apply(quote, to: "word").0 == "\"word\"")
        #expect(quote.selection == NSRange(location: 1, length: 4))

        #expect(
            MarkdownEditing.closingCharacterSelection(
                in: "()", selection: NSRange(location: 1, length: 0), typed: ")")
                == NSRange(location: 2, length: 0))
        #expect(
            MarkdownEditing.closingCharacterSelection(
                in: "(x", selection: NSRange(location: 1, length: 0), typed: ")") == nil)
    }

    @Test func typingThreeBackticksCompletesFencedBlock() throws {
        var text = ""
        var selection = NSRange(location: 0, length: 0)
        for _ in 0..<3 {
            if let edit = MarkdownEditing.completeCodeFence(in: text, selection: selection, typed: "`") {
                (text, selection) = apply(edit, to: text)
            } else if let next = MarkdownEditing.closingCharacterSelection(
                in: text, selection: selection, typed: "`")
            {
                selection = next
            } else {
                let edit = try #require(MarkdownEditing.autoPair(in: text, selection: selection, typed: "`"))
                (text, selection) = apply(edit, to: text)
            }
        }
        #expect(text == "```\n\n```")
        #expect(selection == NSRange(location: 4, length: 0))
    }

    @Test func fenceCompletionReplacesInlineCloserAndPreservesFollowingText() throws {
        let text = "```\nNext paragraph"
        let edit = try #require(MarkdownEditing.completeCodeFence(
            in: text, selection: NSRange(location: 2, length: 0), typed: "`"))
        #expect(apply(edit, to: text).0 == "```\n\n```\nNext paragraph")
        #expect(edit.selection == NSRange(location: 4, length: 0))
    }

    @Test func fenceCompletionPreservesIndentAndWindowsNewlines() throws {
        let text = "  ``\r\nFollowing"
        let edit = try #require(MarkdownEditing.completeCodeFence(
            in: text, selection: NSRange(location: 4, length: 0), typed: "`"))
        #expect(apply(edit, to: text).0 == "  ```\r\n  \r\n  ```\r\nFollowing")
        #expect(edit.selection == NSRange(location: 9, length: 0))
    }

    @Test func fenceCompletionLeavesInlineCodeAndExistingBlocksAlone() {
        for text in ["inline ``", "    ``", "```swift\n``", "```swift\nvalue\n``"] {
            #expect(MarkdownEditing.completeCodeFence(
                in: text, selection: NSRange(location: text.utf16.count, length: 0), typed: "`") == nil)
        }
        #expect(MarkdownEditing.completeCodeFence(
            in: "``", selection: NSRange(location: 0, length: 2), typed: "`") == nil)
    }

    @Test func slashCommandFiltering() {
        #expect(MarkdownEditing.slashCommands(matching: "").count == 6)
        #expect(MarkdownEditing.slashCommands(matching: "code") == [.code])
        #expect(MarkdownEditing.slashCommands(matching: "image") == [.image])
        #expect(MarkdownEditing.slashCommands(matching: "TOD") == [.today])
        #expect(MarkdownEditing.slashCommands(matching: "missing").isEmpty)
    }

    @Test func searchMatchesIncludeCodeAndUseUtf16Ranges() {
        let text = "a😀 Foo\n```swift\nfoo\n```"
        let matches = MarkdownEditing.searchMatches(in: text, query: "foo")
        #expect(matches.count == 2)
        #expect((text as NSString).substring(with: matches[0]) == "Foo")
        #expect((text as NSString).substring(with: matches[1]) == "foo")
        #expect(MarkdownEditing.searchMatches(in: text, query: "").isEmpty)
    }

    @Test func caretAtAdjacentRangeBoundaryTouchesOnlyFollowingRange() {
        let caret = NSRange(location: 10, length: 0)
        #expect(!MarkdownEditing.selection(caret, touches: NSRange(location: 0, length: 10)))
        #expect(MarkdownEditing.selection(caret, touches: NSRange(location: 10, length: 8)))
        #expect(
            MarkdownEditing.selection(
                NSRange(location: 9, length: 2), touches: NSRange(location: 0, length: 10)))
    }

    @Test func imageDestinationIgnoresLineEndingAndOptionalTitle() {
        #expect(MarkdownEditing.imageDestination(in: "![Image](media/a.png)\n") == "media/a.png")
        #expect(MarkdownEditing.imageDestination(in: "![Image](media/a.png)\r\n") == "media/a.png")
        #expect(MarkdownEditing.imageDestination(in: "![Image](media/a.png \"title\")\r\n") == "media/a.png")
    }
}
