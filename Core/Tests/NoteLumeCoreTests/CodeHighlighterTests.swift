import Foundation
import Testing
@testable import NoteLumeCore

@Suite struct CodeHighlighterTests {
    @Test func languageNormalization() {
        #expect(CodeHighlighter.normalize(language: "bash") == .bash)
        #expect(CodeHighlighter.normalize(language: "BASH ") == .bash)
        #expect(CodeHighlighter.normalize(language: "sh") == .bash)
        #expect(CodeHighlighter.normalize(language: "zsh") == .bash)
        #expect(CodeHighlighter.normalize(language: "shell") == .bash)
        #expect(CodeHighlighter.normalize(language: "swift") == .swift)
        #expect(CodeHighlighter.normalize(language: "python") == .python)
        #expect(CodeHighlighter.normalize(language: "py") == .python)
        #expect(CodeHighlighter.normalize(language: "javascript") == .javascript)
        #expect(CodeHighlighter.normalize(language: "js") == .javascript)
        #expect(CodeHighlighter.normalize(language: "ts") == .typescript)
        #expect(CodeHighlighter.normalize(language: "json") == .json)
        #expect(CodeHighlighter.normalize(language: "yaml") == .yaml)
        #expect(CodeHighlighter.normalize(language: "html") == .html)
        #expect(CodeHighlighter.normalize(language: "css") == .css)
        #expect(CodeHighlighter.normalize(language: "sql") == .sql)
        #expect(CodeHighlighter.normalize(language: nil) == .generic)
        #expect(CodeHighlighter.normalize(language: "unknown-lang") == .generic)
    }

    @Test func bashHighlightingTokens() {
        let code = """
        # Build script
        echo "Hello $USER"
        if [ $? -eq 0 ]; then
            git commit -m "done"
        fi
        """
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        let kinds = tokens.map(\.kind)

        #expect(kinds.contains(.comment))
        #expect(kinds.contains(.property))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.variable))
        #expect(kinds.contains(.keyword))

        let ns = code as NSString
        let commentToken = tokens.first { $0.kind == .comment }!
        #expect(ns.substring(with: commentToken.range) == "# Build script")

        let flags = tokens.filter { $0.kind == .property }.map { ns.substring(with: $0.range) }
        #expect(flags.contains("-eq"))
        #expect(flags.contains("-m"))

        let keywordTokens = tokens.filter { $0.kind == .keyword }
        let keywordStrings = keywordTokens.map { ns.substring(with: $0.range) }
        #expect(keywordStrings.contains("if"))
        #expect(keywordStrings.contains("then"))
        #expect(keywordStrings.contains("fi"))
    }

    @Test func bashDoesNotTreatCommentsInsideStringsAsComments() {
        let code = "echo \"# not a comment\""
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        #expect(!tokens.contains { $0.kind == .comment })
        #expect(tokens.contains { $0.kind == .string })
    }

    @Test func bashVariablesInsideStringsKeepTheirColorAndNumbersInsideThemDoNot() {
        let code = "WORK_DIR=$(dirname \"${SRC[0]}\") -maxdepth 2"
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        let ns = code as NSString
        let variables = tokens.filter { $0.kind == .variable }.map { ns.substring(with: $0.range) }
        #expect(variables == ["${SRC[0]}"])
        let numbers = tokens.filter { $0.kind == .number }.map { ns.substring(with: $0.range) }
        #expect(numbers == ["2"])
    }

    @Test func bashDoesNotTreatCommentTextAsFlagsOrKeywords() {
        let code = "# for -x in loop"
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        #expect(tokens.map(\.kind) == [.comment])
    }

    @Test func codeRangeExcludesFences() {
        let doc = "```bash\necho hi\n```\n"
        let span = MarkdownAnalyzer.spans(in: doc).first { if case .codeBlock = $0.kind { true } else { false } }!
        let r = CodeHighlighter.codeRange(in: doc, span: span)!
        #expect((doc as NSString).substring(with: r) == "echo hi")
    }

    @Test func swiftHighlightingTokens() {
        let code = """
        // Example
        func greet(name: String) -> Int {
            let count = 42
            return count
        }
        """
        let tokens = CodeHighlighter.highlight(code: code, language: "swift")
        let ns = code as NSString

        let keywords = tokens.filter { $0.kind == .keyword }.map { ns.substring(with: $0.range) }
        #expect(keywords.contains("func"))
        #expect(keywords.contains("let"))
        #expect(keywords.contains("return"))

        let types = tokens.filter { $0.kind == .type }.map { ns.substring(with: $0.range) }
        #expect(types.contains("String"))
        #expect(types.contains("Int"))

        let numbers = tokens.filter { $0.kind == .number }.map { ns.substring(with: $0.range) }
        #expect(numbers.contains("42"))
    }

    @Test func highlightFromMarkdownSpan() {
        let doc = """
        Intro line

        ```bash
        echo -n "test"
        ```

        Outro line
        """
        let spans = MarkdownAnalyzer.spans(in: doc)
        let blockSpan = spans.first { if case .codeBlock = $0.kind { true } else { false } }!
        let tokens = CodeHighlighter.highlight(in: doc, span: blockSpan)

        let ns = doc as NSString
        let flagToken = tokens.first { $0.kind == .property }!
        #expect(ns.substring(with: flagToken.range) == "-n")

        let stringToken = tokens.first { $0.kind == .string }!
        #expect(ns.substring(with: stringToken.range) == "\"test\"")
    }
}
