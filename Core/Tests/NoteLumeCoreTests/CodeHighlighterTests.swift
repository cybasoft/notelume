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
        #expect(CodeHighlighter.normalize(language: "PHP") == .php)
        #expect(CodeHighlighter.normalize(language: "phtml") == .php)
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

    @Test func bashHighlightsShebangAndCommandsWithoutColoringAssignments() {
        let code = "#!/bin/bash\nTEST=live\necho this should be code\necho \"Hi\""
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        let ns = code as NSString
        #expect(tokens.contains { $0.kind == .property && ns.substring(with: $0.range) == "#!/bin/bash" })
        #expect(tokens.filter { $0.kind == .command }.map { ns.substring(with: $0.range) } == ["echo", "echo"])
        #expect(!tokens.contains { NSIntersectionRange($0.range, ns.range(of: "TEST=live")).length > 0 })
    }

    @Test func bashDoesNotInterpolateSingleQuotedStringsOrComments() {
        let code = "echo '$USER'\n# $HOME\necho \"$USER\""
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        #expect(tokens.filter { $0.kind == .variable }.map(\.range) == [(code as NSString).range(of: "$USER", options: .backwards)])
    }

    @Test func bashQuotesInsideCommentsStayComments() {
        let code = "# echo \"$USER\" 'if'\necho \"# not a comment\""
        let tokens = CodeHighlighter.highlight(code: code, language: "bash")
        let ns = code as NSString
        #expect(tokens.filter { $0.kind == .comment }.map { ns.substring(with: $0.range) } == ["# echo \"$USER\" 'if'"])
        #expect(tokens.filter { $0.kind == .string }.map { ns.substring(with: $0.range) } == ["\"# not a comment\""])
        #expect(!tokens.contains { $0.kind == .variable })
    }

    @Test func cssHighlightsSelectorsPropertiesAndValues() {
        let code = ".div {\n  color: \"red\";\n}\n#main, body { display: flex; }"
        let tokens = CodeHighlighter.highlight(code: code, language: "css")
        let ns = code as NSString
        let selectors = tokens.filter { $0.kind == .type }.map { ns.substring(with: $0.range) }
        #expect(selectors.contains(".div"))
        #expect(selectors.contains("#main"))
        #expect(selectors.contains("body"))
        #expect(tokens.contains { $0.kind == .property && ns.substring(with: $0.range) == "color" })
        #expect(tokens.contains { $0.kind == .property && ns.substring(with: $0.range) == "display" })
        #expect(tokens.contains { $0.kind == .string && ns.substring(with: $0.range) == "\"red\"" })
    }

    @Test func cssDistinguishesHexColorsFromIdSelectors() {
        let code = "#abc { color: #fff; background: url(\"/image.png\"); }"
        let tokens = CodeHighlighter.highlight(code: code, language: "css")
        let ns = code as NSString
        #expect(tokens.contains { $0.kind == .type && ns.substring(with: $0.range) == "#abc" })
        #expect(tokens.contains { $0.kind == .number && ns.substring(with: $0.range) == "#fff" })
        #expect(tokens.contains { $0.kind == .command && ns.substring(with: $0.range) == "url" })
        #expect(!tokens.contains { $0.kind == .type && ns.substring(with: $0.range).contains("image") })
    }

    @Test func phpHighlightsCodeWithoutAnOpeningTag() {
        let code = "class Example {\n  function testing() {\n    echo \"This is a test\";\n    return $value;\n  }\n}"
        let tokens = CodeHighlighter.highlight(code: code, language: "php")
        let ns = code as NSString
        #expect(tokens.contains { $0.kind == .keyword && ns.substring(with: $0.range) == "class" })
        #expect(tokens.contains { $0.kind == .type && ns.substring(with: $0.range) == "testing" })
        #expect(tokens.contains { $0.kind == .command && ns.substring(with: $0.range) == "echo" })
        #expect(tokens.contains { $0.kind == .variable && ns.substring(with: $0.range) == "$value" })
        #expect(tokens.contains { $0.kind == .string && ns.substring(with: $0.range) == "\"This is a test\"" })
    }

    @Test func phpKeepsCommentAndStringContentsOutOfKeywordHighlighting() {
        let code = "// echo \"class\"\n$value = \"https://example.com/function\"; /* return $value */"
        let tokens = CodeHighlighter.highlight(code: code, language: "php")
        #expect(tokens.filter { $0.kind == .comment }.count == 2)
        #expect(tokens.filter { $0.kind == .string }.count == 1)
        #expect(!tokens.contains { $0.kind == .keyword || $0.kind == .command })
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
