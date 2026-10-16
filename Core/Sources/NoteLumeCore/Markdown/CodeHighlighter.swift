import Foundation

public struct CodeToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyword
        case command
        case string
        case comment
        case number
        case variable
        case type
        case property
        case tag
    }

    public var kind: Kind
    public var range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum CodeHighlighter {
    public enum Language: String, Sendable {
        case bash
        case swift
        case python
        case javascript
        case typescript
        case json
        case yaml
        case html
        case css
        case sql
        case php
        case generic
    }

    public static func normalize(language: String?) -> Language {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .generic
        }
        switch raw {
        case "bash", "sh", "zsh", "shell", "console", "terminal":
            return .bash
        case "swift":
            return .swift
        case "python", "py":
            return .python
        case "javascript", "js", "jsx", "mjs", "cjs":
            return .javascript
        case "typescript", "ts", "tsx":
            return .typescript
        case "json":
            return .json
        case "yaml", "yml":
            return .yaml
        case "html", "xml", "svg":
            return .html
        case "css", "scss", "less":
            return .css
        case "sql":
            return .sql
        case "php", "php8", "phtml":
            return .php
        default:
            return .generic
        }
    }

    /// Range of the code inside a code block span, excluding the fence lines.
    public static func codeRange(in text: String, span: MarkdownSpan) -> NSRange? {
        guard case .codeBlock = span.kind else { return nil }
        let ns = text as NSString
        guard NSMaxRange(span.range) <= ns.length else { return nil }

        var start = span.range.location
        if let firstSyntax = span.syntax.first {
            start = NSMaxRange(firstSyntax)
            if start < ns.length, ns.character(at: start) == 0x0A /* \n */ {
                start += 1
            } else if start + 1 < ns.length, ns.character(at: start) == 0x0D, ns.character(at: start + 1) == 0x0A {
                start += 2
            }
        }

        var end = NSMaxRange(span.range)
        if span.syntax.count > 1 {
            end = span.syntax[1].location
            if end > start, end <= ns.length, ns.character(at: end - 1) == 0x0A {
                end -= 1
                if end > start, ns.character(at: end - 1) == 0x0D {
                    end -= 1
                }
            }
        }

        guard end > start, start >= 0, end <= ns.length else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Extracts and highlights code from a code block span in `text`.
    public static func highlight(in text: String, span: MarkdownSpan) -> [CodeToken] {
        guard case .codeBlock(let language) = span.kind, let r = codeRange(in: text, span: span) else { return [] }
        let code = (text as NSString).substring(with: r)
        return highlight(code: code, language: language, offset: r.location)
    }

    /// Tokenizes `code` for syntax highlighting, adding `offset` to all token ranges.
    public static func highlight(code: String, language: String?, offset: Int = 0) -> [CodeToken] {
        guard !code.isEmpty else { return [] }
        let lang = normalize(language: language)
        let tokens = tokenize(code: code, language: lang)
        if offset == 0 { return tokens }
        return tokens.map { CodeToken(kind: $0.kind, range: NSRange(location: $0.range.location + offset, length: $0.range.length)) }
    }

    private static func tokenize(code: String, language: Language) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var occupied = IndexSet()
        var protected = IndexSet()

        func collect(regex: NSRegularExpression, kind: CodeToken.Kind, group: Int = 0, allowInOccupied: Bool = false) {
            let ns = code as NSString
            let full = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let match = match else { return }
                let r = match.range(at: group)
                guard r.location != NSNotFound, r.length > 0 else { return }
                guard let range = Range(r) else { return }
                if (allowInOccupied || !occupied.intersects(integersIn: range)),
                    !protected.intersects(integersIn: range)
                {
                    tokens.append(CodeToken(kind: kind, range: r))
                    occupied.insert(integersIn: range)
                }
            }
        }

        switch language {
        case .bash:
            let ns = code as NSString
            Regexes.bashLiterals.enumerateMatches(
                in: code, range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let range = match?.range, let indexes = Range(range) else { return }
                let literal = ns.substring(with: range)
                let comment = literal.hasPrefix("#")
                let kind: CodeToken.Kind = literal.hasPrefix("#!") && range.location == 0
                    ? .property : (comment ? .comment : .string)
                tokens.append(CodeToken(kind: kind, range: range))
                occupied.insert(integersIn: indexes)
                if comment || literal.hasPrefix("'") { protected.insert(integersIn: indexes) }
            }

            // 3. Variables (can appear inside double quotes or standalone)
            collect(regex: Regexes.bashVariables, kind: .variable, allowInOccupied: true)

            // 4. Flags, keywords, commands and numbers.
            collect(regex: Regexes.bashFlags, kind: .property, group: 1)
            collect(regex: Regexes.bashKeywords, kind: .keyword)
            collect(regex: Regexes.bashCommands, kind: .command, group: 1)
            collect(regex: Regexes.numbers, kind: .number)

        case .swift:
            collect(regex: Regexes.multilineStrings, kind: .string)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.slashStarComments, kind: .comment)
            collect(regex: Regexes.slashSlashComments, kind: .comment)
            collect(regex: Regexes.swiftKeywords, kind: .keyword)
            collect(regex: Regexes.types, kind: .type)
            collect(regex: Regexes.swiftNumbers, kind: .number)

        case .python:
            collect(regex: Regexes.pythonMultilineDouble, kind: .string)
            collect(regex: Regexes.pythonMultilineSingle, kind: .string)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.bashComments, kind: .comment)
            collect(regex: Regexes.pythonDecorators, kind: .property)
            collect(regex: Regexes.pythonKeywords, kind: .keyword)
            collect(regex: Regexes.pythonBuiltins, kind: .command)
            collect(regex: Regexes.numbers, kind: .number)

        case .javascript, .typescript:
            collect(regex: Regexes.templateStrings, kind: .string)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.slashStarComments, kind: .comment)
            collect(regex: Regexes.slashSlashComments, kind: .comment)
            collect(regex: Regexes.jsKeywords, kind: .keyword)
            collect(regex: Regexes.jsBuiltins, kind: .command)
            collect(regex: Regexes.types, kind: .type)
            collect(regex: Regexes.numbers, kind: .number)

        case .json:
            let ns = code as NSString
            let full = NSRange(location: 0, length: ns.length)
            Regexes.jsonKeyOrString.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let match = match else { return }
                let strRange = match.range(at: 1)
                guard strRange.location != NSNotFound, let r = Range(strRange) else { return }
                let colonRange = match.range(at: 2)
                let isKey = colonRange.location != NSNotFound
                tokens.append(CodeToken(kind: isKey ? .property : .string, range: strRange))
                occupied.insert(integersIn: r)
            }
            collect(regex: Regexes.jsonKeywords, kind: .keyword)
            collect(regex: Regexes.numbers, kind: .number)

        case .yaml:
            collect(regex: Regexes.bashComments, kind: .comment)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.yamlKeys, kind: .property, group: 1)
            collect(regex: Regexes.yamlKeywords, kind: .keyword)
            collect(regex: Regexes.numbers, kind: .number)

        case .html:
            collect(regex: Regexes.htmlComments, kind: .comment)
            collect(regex: Regexes.htmlTags, kind: .tag)
            collect(regex: Regexes.htmlAttributes, kind: .property, group: 1)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)

        case .css:
            collect(regex: Regexes.slashStarComments, kind: .comment)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.cssProperties, kind: .property, group: 1)
            collect(regex: Regexes.cssSelectors, kind: .type)
            collect(regex: Regexes.cssColors, kind: .number)
            collect(regex: Regexes.cssAtRules, kind: .keyword)
            collect(regex: Regexes.functionCalls, kind: .command, group: 1)
            collect(regex: Regexes.numbers, kind: .number)

        case .php:
            let ns = code as NSString
            Regexes.phpLiterals.enumerateMatches(
                in: code, range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let range = match?.range, let indexes = Range(range) else { return }
                let literal = ns.substring(with: range)
                let comment = literal.hasPrefix("//") || literal.hasPrefix("/*") || literal.hasPrefix("#")
                tokens.append(CodeToken(kind: comment ? .comment : .string, range: range))
                occupied.insert(integersIn: indexes)
            }
            collect(regex: Regexes.phpTags, kind: .tag)
            collect(regex: Regexes.phpVariables, kind: .variable)
            collect(regex: Regexes.phpKeywords, kind: .keyword)
            collect(regex: Regexes.phpDeclarations, kind: .type, group: 1)
            collect(regex: Regexes.phpBuiltins, kind: .command)
            collect(regex: Regexes.functionCalls, kind: .command, group: 1)
            collect(regex: Regexes.types, kind: .type)
            collect(regex: Regexes.numbers, kind: .number)

        case .sql:
            collect(regex: Regexes.slashStarComments, kind: .comment)
            collect(regex: Regexes.sqlDashComments, kind: .comment)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.sqlKeywords, kind: .keyword)
            collect(regex: Regexes.numbers, kind: .number)

        case .generic:
            collect(regex: Regexes.slashStarComments, kind: .comment)
            collect(regex: Regexes.slashSlashComments, kind: .comment)
            collect(regex: Regexes.bashComments, kind: .comment)
            collect(regex: Regexes.doubleQuoteStrings, kind: .string)
            collect(regex: Regexes.singleQuoteStrings, kind: .string)
            collect(regex: Regexes.genericKeywords, kind: .keyword)
            collect(regex: Regexes.numbers, kind: .number)
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private enum Regexes {
        static let bashComments = try! NSRegularExpression(pattern: "(?m)#.*$")
        static let bashLiterals = try! NSRegularExpression(pattern: #"\A#![^\r\n]*|'[^']*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|#[^\r\n]*"#)
        static let bashVariables = try! NSRegularExpression(pattern: "\\$([a-zA-Z_][a-zA-Z0-9_]*|\\{[^}]+\\}|[0-9?*@#$!-])")
        static let bashKeywords = try! NSRegularExpression(pattern: "\\b(if|then|else|elif|fi|case|esac|for|select|while|until|do|done|in|function|time|return|exit|break|continue|local|export|readonly|declare|typeset|set|unset|shift)\\b")
        static let bashFlags = try! NSRegularExpression(pattern: "(?:\\s|^)(--?[a-zA-Z0-9_-]+)")
        static let bashCommands = try! NSRegularExpression(pattern: "(?m)(?:^|[;|&])[ \\t]*([a-zA-Z_][a-zA-Z0-9_./-]*)(?=[ \\t]|$)")

        static let slashSlashComments = try! NSRegularExpression(pattern: "(?m)//.*$")
        static let slashStarComments = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
        static let sqlDashComments = try! NSRegularExpression(pattern: "(?m)--.*$")
        static let htmlComments = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")

        static let doubleQuoteStrings = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\r\n])*\"")
        static let singleQuoteStrings = try! NSRegularExpression(pattern: "'(\\\\.|[^'\\\r\n])*'")
        static let multilineStrings = try! NSRegularExpression(pattern: "\"\"\"[\\s\\S]*?\"\"\"")
        static let templateStrings = try! NSRegularExpression(pattern: "`(\\\\.|[^`\\\\])*`")
        static let pythonMultilineDouble = try! NSRegularExpression(pattern: "\"\"\"[\\s\\S]*?\"\"\"")
        static let pythonMultilineSingle = try! NSRegularExpression(pattern: "'''[\\s\\S]*?'''")

        static let numbers = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
        static let swiftNumbers = try! NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F_]+|0b[01_]+|\\d[\\d_]*(\\.[\\d_]+)?)\\b")

        static let types = try! NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b")

        static let swiftKeywords = try! NSRegularExpression(pattern: "\\b(func|var|let|if|else|guard|switch|case|default|for|in|while|repeat|return|throw|throws|rethrows|try|catch|class|struct|enum|protocol|extension|import|init|deinit|subscript|typealias|associatedtype|public|private|fileprivate|internal|open|static|final|mutating|nonmutating|override|weak|unowned|lazy|some|any|async|await|actor|self|Self|super|nil|true|false|where|break|continue|fallthrough)\\b")

        static let pythonKeywords = try! NSRegularExpression(pattern: "\\b(def|class|import|from|as|return|if|elif|else|for|while|break|continue|try|except|finally|raise|with|yield|lambda|pass|assert|async|await|global|nonlocal|in|is|not|and|or|True|False|None)\\b")
        static let pythonBuiltins = try! NSRegularExpression(pattern: "\\b(print|len|range|str|int|float|list|dict|set|tuple|open|type|isinstance|enumerate|zip|map|filter|any|all|sum|min|max|abs|round|super|self)\\b")
        static let pythonDecorators = try! NSRegularExpression(pattern: "@[a-zA-Z_][a-zA-Z0-9_.]*")

        static let jsKeywords = try! NSRegularExpression(pattern: "\\b(const|let|var|function|return|if|else|for|while|do|switch|case|default|break|continue|try|catch|finally|throw|new|class|extends|super|import|export|from|async|await|yield|this|typeof|instanceof|in|of|void|delete|null|undefined|true|false|type|interface|enum|implements|declare|abstract|as|keyof|readonly)\\b")
        static let jsBuiltins = try! NSRegularExpression(pattern: "\\b(console|window|document|Math|JSON|Promise|Array|Object|String|Number|Boolean|Date|RegExp|Map|Set|Error|setTimeout|setInterval|fetch)\\b")

        static let jsonKeyOrString = try! NSRegularExpression(pattern: "(\"(\\\\.|[^\"\\\r\n])*\")(\\s*:)?")
        static let jsonKeywords = try! NSRegularExpression(pattern: "\\b(true|false|null)\\b")

        static let yamlKeys = try! NSRegularExpression(pattern: "(?m)^[ \\t]*([a-zA-Z0-9_-]+)(?=\\s*:)")
        static let yamlKeywords = try! NSRegularExpression(pattern: "\\b(true|false|null|yes|no|on|off)\\b")

        static let htmlTags = try! NSRegularExpression(pattern: "</?[a-zA-Z0-9:-]+|/?>")
        static let htmlAttributes = try! NSRegularExpression(pattern: "\\b([a-zA-Z0-9:-]+)(?=\\=)")

        static let cssProperties = try! NSRegularExpression(pattern: "(?m)(?:^|[;{])[ \\t]*([a-zA-Z_-][a-zA-Z0-9_-]*)(?=\\s*:)")
        static let cssColors = try! NSRegularExpression(pattern: "#[0-9a-fA-F]{3,8}\\b")
        static let cssSelectors = try! NSRegularExpression(pattern: "[.#][a-zA-Z_][a-zA-Z0-9_-]*(?=[^;{}]*\\{)|[a-zA-Z][a-zA-Z0-9_-]*(?=[ \\t]*[,{])")
        static let cssAtRules = try! NSRegularExpression(pattern: "@[a-zA-Z-]+|!important\\b")
        static let functionCalls = try! NSRegularExpression(pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)(?=\\s*\\()")

        static let phpLiterals = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|/\*[\s\S]*?\*/|//[^\r\n]*|#[^\r\n]*"#)
        static let phpTags = try! NSRegularExpression(pattern: "<\\?(?:php|=)?|\\?>", options: .caseInsensitive)
        static let phpVariables = try! NSRegularExpression(pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*")
        static let phpKeywords = try! NSRegularExpression(pattern: "\\b(class|function|fn|public|protected|private|static|final|abstract|extends|implements|interface|trait|namespace|use|new|return|if|else|elseif|foreach|for|while|do|switch|case|default|break|continue|try|catch|finally|throw|match|yield|as|instanceof|const|var|readonly|true|false|null)\\b", options: .caseInsensitive)
        static let phpDeclarations = try! NSRegularExpression(pattern: "\\b(?:function\\s+&?\\s*|(?:class|interface|trait)\\s+)([a-zA-Z_][a-zA-Z0-9_]*)", options: .caseInsensitive)
        static let phpBuiltins = try! NSRegularExpression(pattern: "\\b(echo|print|isset|empty|unset|include|include_once|require|require_once|array|list|exit|die)\\b", options: .caseInsensitive)

        static let sqlKeywords = try! NSRegularExpression(pattern: "(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|UPDATE|DELETE|CREATE|TABLE|DROP|ALTER|JOIN|LEFT|RIGHT|INNER|OUTER|FULL|ON|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|AS|AND|OR|NOT|IN|IS|NULL|LIKE|BETWEEN|EXISTS|CASE|WHEN|THEN|ELSE|END|PRIMARY|KEY|FOREIGN|REFERENCES|INDEX|VIEW|TRIGGER|DEFAULT|CHECK|VALUES|SET|WITH|TRUE|FALSE)\\b")

        static let genericKeywords = try! NSRegularExpression(pattern: "\\b(true|false|null|nil|if|else|return|function|class|import|def|var|let|const|public|private)\\b")
    }
}
