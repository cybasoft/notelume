import AppKit
import NoteLumeCore
import SwiftUI

extension NSAttributedString.Key {
    /// Marks source characters replaced by image and divider previews in visual mode.
    static let qnHidden = NSAttributedString.Key("notelume.hidden")
    static let qnForegroundRole = NSAttributedString.Key("notelume.foregroundRole")
}

/// Live-Markdown editor.
///
/// The text storage always holds the raw Markdown body (frontmatter is never
/// loaded into it). Visual mode only *decorates* that text, so visual and source
/// mode edit exactly the same canonical content, and syntax the styler does not
/// understand is simply left as plain text (requirements §4).
struct MarkdownEditor: NSViewRepresentable {
    let text: String
    let revision: Int
    let mode: EditorMode
    let textColor: NSColor
    var codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    let labels: [String]
    let notesDirectory: URL?
    let searchQuery: String
    let searchRequest: Int
    let onChange: (String) -> Void
    let onAddTags: ([String]) -> Int
    let onTagsAdded: (Int) -> Void
    let onRawModeChange: (Bool) -> Void
    let onCopy: () -> Void
    let onPasteNotice: (EditorPasteNotice) -> Void
    let onPasteImage: (Data, @escaping (String) -> Void) -> Void
    let onChooseImage: (@escaping (Data) -> Void) -> Void
    let onImageAdded: () -> Void
    let onFind: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let tv = MarkdownTextView(frame: .zero, textContainer: container)
        tv.isRichText = true  // attributes are decoration only; paste is forced to plain text
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        layout.delegate = context.coordinator
        tv.coordinator = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        context.coordinator.attach(tv)
        context.coordinator.load(text: text, revision: revision)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
        -> CGSize?
    {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(text: text, revision: revision)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        private enum ForegroundRole {
            case body
            case token(CodeToken.Kind)
            case fixed
        }

        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        private var appliedRevision = -1
        private var appliedMode: EditorMode?
        private var appliedColor: NSColor?
        private var appliedCodeFont: NSFont?
        private var isProgrammatic = false
        private var cachedText: String?
        private var cachedSpans: [MarkdownSpan] = []
        private var cachedCodeTokens: [Int: [CodeToken]] = [:]
        private var appliedSelectionSpans: [Int] = []
        private var hiddenRanges: [NSRange] = []
        private var rawCodeBlocks = Set<Int>()
        private var codeLineNumbers = Set<Int>()
        private var isPeekingRaw = false
        private var localImageCache: [URL: NSImage] = [:]
        private var searchMatches: [NSRange] = []
        private var activeSearchIndex = -1
        private var searchRequest = 0
        private var appliedSearchQuery = ""

        var appliedTextColor: NSColor { appliedColor ?? parent.textColor }
        var isVisual: Bool { parent.mode == .visual && !isPeekingRaw }

        func isRawCodeBlock(at location: Int) -> Bool { rawCodeBlocks.contains(location) }
        func showsLineNumbers(at location: Int) -> Bool { codeLineNumbers.contains(location) }

        func toggleRawCodeBlock(at location: Int) {
            if rawCodeBlocks.contains(location) {
                rawCodeBlocks.remove(location)
            } else {
                rawCodeBlocks.insert(location)
            }
            restyle(force: true)
            notifyRawModeChange()
        }

        func toggleCodeLineNumbers(at location: Int) {
            if codeLineNumbers.contains(location) {
                codeLineNumbers.remove(location)
            } else {
                codeLineNumbers.insert(location)
            }
            restyle(force: true)
        }

        func setPeekRaw(_ enabled: Bool) {
            guard isPeekingRaw != enabled else { return }
            isPeekingRaw = enabled
            restyle(force: true)
            guard let textView else { return }
            NSAccessibility.post(
                element: textView, notification: .announcementRequested,
                userInfo: [
                    .announcement: enabled ? "Raw Markdown view on" : "Raw Markdown view off"
                ])
            notifyRawModeChange()
        }

        func notifyRawModeChange() {
            parent.onRawModeChange(parent.mode == .source || isPeekingRaw || !rawCodeBlocks.isEmpty)
        }
        var codeBlockSpans: [MarkdownSpan] {
            cachedSpans.filter { if case .codeBlock = $0.kind { true } else { false } }
        }
        var imageSpans: [MarkdownSpan] {
            cachedSpans.filter { if case .image = $0.kind { true } else { false } }
        }
        var thematicBreakSpans: [MarkdownSpan] {
            cachedSpans.filter { if case .thematicBreak = $0.kind { true } else { false } }
        }
        var checkboxSpans: [MarkdownSpan] {
            cachedSpans.filter { if case .checkbox = $0.kind { true } else { false } }
        }
        var blockQuoteSpans: [MarkdownSpan] {
            cachedSpans.filter { if case .blockQuote = $0.kind { true } else { false } }
        }

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func attach(_ tv: MarkdownTextView) { textView = tv }

        func load(text: String, revision: Int) {
            guard let tv = textView else { return }
            isProgrammatic = true
            tv.string = text
            isProgrammatic = false
            appliedRevision = revision
            restyle(force: true)
        }

        /// SwiftUI pushed new state: external text, mode or color changes.
        func sync(text: String, revision: Int) {
            guard let tv = textView else { return }
            if revision != appliedRevision {
                let selection = tv.selectedRange()
                isProgrammatic = true
                tv.string = text
                isProgrammatic = false
                appliedRevision = revision
                let len = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: min(selection.location, len), length: 0))
                restyle(force: true)
                return
            }
            let modeChanged = appliedMode != parent.mode
            if modeChanged || appliedCodeFont != parent.codeFont {
                restyle(force: true)
                if modeChanged { notifyRawModeChange() }
            } else if appliedColor != parent.textColor {
                updateTextColors()
            }
            if searchRequest != parent.searchRequest {
                let direction = parent.searchRequest - searchRequest
                searchRequest = parent.searchRequest
                moveToSearchResult(direction: direction)
            } else if appliedSearchQuery != parent.searchQuery {
                appliedSearchQuery = parent.searchQuery
                activeSearchIndex = -1
                restyle(force: true)
            }
        }

        private func moveToSearchResult(direction: Int) {
            searchMatches = MarkdownEditing.searchMatches(
                in: textView?.string ?? "", query: parent.searchQuery)
            guard !searchMatches.isEmpty else {
                activeSearchIndex = -1
                restyle(force: false)
                return
            }
            if activeSearchIndex < 0 {
                activeSearchIndex = direction >= 0 ? 0 : searchMatches.count - 1
            } else {
                activeSearchIndex =
                    (activeSearchIndex + (direction >= 0 ? 1 : -1) + searchMatches.count)
                    % searchMatches.count
            }
            textView?.setSelectedRange(searchMatches[activeSearchIndex])
            textView?.scrollRangeToVisible(searchMatches[activeSearchIndex])
            restyle(force: false)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isProgrammatic, let tv = textView else { return }
            let text = tv.string
            parent.onChange(text)
            restyle(force: false)
            updateSpellingCorrection(for: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammatic else { return }
            if let tv = textView { updateSpellingCorrection(for: tv) }
            if cachedText != textView?.string || selectionSpans() != appliedSelectionSpans {
                restyle(force: false)
            } else {
                textView?.needsDisplay = true
            }
        }

        private func selectionSpans() -> [Int] {
            guard visual, let textView else { return [] }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            return cachedSpans.indices.filter { index in
                let span = cachedSpans[index]
                guard NSMaxRange(span.range) <= text.length else { return false }
                if span.syntax.isEmpty {
                    guard case .image = span.kind else { return false }
                }
                return MarkdownEditing.selection(selection, touches: text.lineRange(for: span.range))
            }
        }

        private func updateSpellingCorrection(for textView: NSTextView) {
            let location = textView.selectedRange().location
            let inCode = codeBlockSpans.contains { span in
                guard let range = CodeHighlighter.codeRange(in: textView.string, span: span) else {
                    return false
                }
                return location >= range.location && location < NSMaxRange(range)
            }
            textView.isAutomaticSpellingCorrectionEnabled = !inCode
        }

        /// Correct code looks broken with squiggles under `venv`, `maxdepth`, …
        func textView(
            _ textView: NSTextView, shouldSetSpellingState value: Int,
            range affectedCharRange: NSRange
        ) -> Int {
            for span in cachedSpans {
                switch span.kind {
                case .codeBlock, .inlineCode:
                    if NSIntersectionRange(span.range, affectedCharRange).length > 0 { return 0 }
                default: break
                }
            }
            return value
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let tv = textView as? MarkdownTextView else { return false }
            let text = tv.string
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let edit = MarkdownEditing.continueList(in: text, selection: tv.selectedRange())
                    ?? MarkdownEditing.continueQuote(in: text, selection: tv.selectedRange())
                {
                    tv.apply(edit)
                    return true
                }
            case #selector(NSResponder.insertTab(_:)):
                if let edit = MarkdownEditing.indentCode(
                    in: text, selection: tv.selectedRange(), outdent: false)
                    ?? MarkdownEditing.indent(
                        in: text, selection: tv.selectedRange(), outdent: false)
                {
                    tv.apply(edit)
                    return true
                }
            case #selector(NSResponder.insertBacktab(_:)):
                if let edit = MarkdownEditing.indentCode(
                    in: text, selection: tv.selectedRange(), outdent: true)
                    ?? MarkdownEditing.indent(
                        in: text, selection: tv.selectedRange(), outdent: true)
                {
                    tv.apply(edit)
                    return true
                }
            case #selector(NSResponder.moveDown(_:)):
                if let edit = MarkdownEditing.escapeCodeBlock(
                    in: text, selection: tv.selectedRange(), onlyAtLastLine: true)
                {
                    tv.apply(edit)
                    return true
                }
            default: break
            }
            return false
        }

        // MARK: Hidden syntax

        func layoutManager(
            _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage, !hiddenRanges.isEmpty else { return 0 }
            var modified = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
            var changed = false
            for i in 0..<glyphRange.length {
                modified[i] = props[i]
                let idx = charIndexes[i]
                if idx < storage.length,
                    storage.attribute(.qnHidden, at: idx, effectiveRange: nil) != nil
                {
                    modified[i] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(
                glyphs, properties: modified, characterIndexes: charIndexes, font: aFont,
                forGlyphRange: glyphRange)
            return glyphRange.length
        }

        func linkDestination(at index: Int) -> URL? {
            for span in cachedSpans {
                if case .link(let dest) = span.kind, let dest, NSLocationInRange(index, span.range)
                {
                    return URL(string: dest)
                }
            }
            return nil
        }

        func localImageURL(for span: MarkdownSpan) -> URL? {
            guard case .image = span.kind, let directory = parent.notesDirectory,
                let cachedText, NSMaxRange(span.range) <= (cachedText as NSString).length
            else { return nil }
            let source = (cachedText as NSString).substring(with: span.range)
            guard let rawPath = MarkdownEditing.imageDestination(in: source) else { return nil }
            guard rawPath.hasPrefix("media/"), !rawPath.split(separator: "/").contains(".."),
                URL(fileURLWithPath: rawPath).pathExtension.lowercased() == "png"
            else { return nil }
            let mediaRoot = directory.appendingPathComponent("media", isDirectory: true)
                .standardizedFileURL
            let url = directory.appendingPathComponent(rawPath).standardizedFileURL
            guard url.path.hasPrefix(mediaRoot.path + "/") else { return nil }
            return url
        }

        func localImage(for span: MarkdownSpan) -> NSImage? {
            guard let url = localImageURL(for: span) else { return nil }
            if let image = localImageCache[url] { return image }
            guard let image = NSImage(contentsOf: url) else { return nil }
            localImageCache[url] = image
            return image
        }

        // MARK: Styling

        private var visual: Bool { isVisual }

        private func baseFont() -> NSFont {
            visual
                ? NSFont.systemFont(ofSize: 14)
                : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        private func baseAttributes() -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = visual ? 1.18 : 1.1
            style.paragraphSpacing = visual ? 3 : 0
            return [
                .font: baseFont(), .foregroundColor: parent.textColor, .paragraphStyle: style,
                .qnForegroundRole: ForegroundRole.body,
            ]
        }

        private func setColor(
            _ color: NSColor, role: ForegroundRole = .fixed,
            in storage: NSTextStorage, range: NSRange
        ) {
            storage.addAttributes(
                [.foregroundColor: color, .qnForegroundRole: role], range: range)
        }

        private func updateTextColors() {
            guard !isProgrammatic, let tv = textView, let storage = tv.textStorage,
                !tv.hasMarkedText()
            else { return }
            isProgrammatic = true
            defer { isProgrammatic = false }
            let full = NSRange(location: 0, length: storage.length)
            let isDark = parent.textColor.luminance > 0.5
            var changes: [(NSRange, NSColor)] = []
            storage.enumerateAttributes(in: full) { attributes, range, _ in
                guard let role = attributes[.qnForegroundRole] as? ForegroundRole else { return }
                let color: NSColor
                switch role {
                case .body: color = parent.textColor
                case .token(let kind): color = Self.tokenColor(kind, isDark: isDark)
                case .fixed: return
                }
                if attributes[.foregroundColor] as? NSColor != color {
                    changes.append((range, color))
                }
            }
            storage.beginEditing()
            for (range, color) in changes {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
            appliedColor = parent.textColor
            tv.typingAttributes = baseAttributes()
            tv.insertionPointColor = parent.textColor
            tv.needsDisplay = true
        }

        func restyle(force: Bool) {
            guard !isProgrammatic, let tv = textView, let storage = tv.textStorage,
                !tv.hasMarkedText()
            else {
                return
            }
            isProgrammatic = true
            defer { isProgrammatic = false }
            let text = storage.string
            let full = NSRange(location: 0, length: storage.length)
            let base = baseAttributes()

            if cachedText != text {
                // Very large notes stay plain: styling must never make typing laggy.
                cachedSpans = storage.length > 300_000 ? [] : MarkdownAnalyzer.spans(in: text)
                cachedCodeTokens.removeAll(keepingCapacity: true)
                cachedText = text
            }
            appliedMode = parent.mode
            appliedColor = parent.textColor
            appliedCodeFont = parent.codeFont

            let ns = text as NSString
            let sel = tv.selectedRange()
            var newHidden: [NSRange] = []

            storage.beginEditing()
            storage.setAttributes(base, range: full)
            for span in cachedSpans { style(span, in: storage, base: base) }

            // Syntax markers retain their metrics so selection changes cannot reflow the note.
            for span in cachedSpans {
                for r in span.syntax where NSMaxRange(r) <= storage.length {
                    if visual, case .checkbox = span.kind { continue }
                    if visual, case .blockQuote = span.kind {
                        setColor(.clear, in: storage, range: r)
                        continue
                    }
                    let rawCode: Bool
                    if case .codeBlock = span.kind {
                        rawCode = rawCodeBlocks.contains(span.range.location)
                    } else {
                        rawCode = false
                    }
                    if visual && !rawCode {
                        let lines = ns.lineRange(for: span.range)
                        let touching = MarkdownEditing.selection(sel, touches: lines)
                        if touching {
                            setColor(.tertiaryLabelColor, in: storage, range: r)
                        } else {
                            setColor(.clear, in: storage, range: r)
                        }
                    } else {
                        setColor(.tertiaryLabelColor, in: storage, range: r)
                    }
                }
                if visual, case .thematicBreak = span.kind, span.range.length > 0 {
                    storage.addAttribute(.qnHidden, value: true, range: span.range)
                    newHidden.append(span.range)
                }
                if visual, case .image = span.kind, localImage(for: span) != nil {
                    let line = ns.lineRange(for: span.range)
                    let touching = MarkdownEditing.selection(sel, touches: line)
                    if !touching {
                        storage.addAttribute(.qnHidden, value: true, range: span.range)
                        newHidden.append(span.range)
                    }
                }
            }
            if visual {
                for span in checkboxSpans where NSMaxRange(span.range) <= storage.length {
                    setColor(.clear, in: storage, range: span.range)
                }
            }
            searchMatches = MarkdownEditing.searchMatches(in: text, query: parent.searchQuery)
            for (index, range) in searchMatches.enumerated()
            where NSMaxRange(range) <= storage.length {
                let color =
                    index == activeSearchIndex
                    ? NSColor.systemOrange.withAlphaComponent(0.45)
                    : NSColor.systemYellow.withAlphaComponent(0.3)
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
            storage.endEditing()

            tv.typingAttributes = base
            tv.insertionPointColor = parent.textColor
            if newHidden != hiddenRanges || force {
                hiddenRanges = newHidden
                tv.layoutManager?.invalidateGlyphs(
                    forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
                tv.layoutManager?.invalidateLayout(
                    forCharacterRange: full, actualCharacterRange: nil)
            }
            tv.needsLayout = true
            tv.needsDisplay = true
            tv.invalidateCodeCards()
            appliedSelectionSpans = selectionSpans()
        }

        private func style(
            _ span: MarkdownSpan, in storage: NSTextStorage, base: [NSAttributedString.Key: Any]
        ) {
            let r = span.range
            guard NSMaxRange(r) <= storage.length, r.length > 0 else { return }
            let accent = NSColor.controlAccentColor
            let baseSize = (base[.font] as? NSFont)?.pointSize ?? 14

            switch span.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0]
                let size = visual ? baseSize * sizes[min(level, 6) - 1] : baseSize
                setFont(storage, r) {
                    NSFontManager.shared.convert($0.withSize(size), toHaveTrait: .boldFontMask)
                }
                if !visual { setColor(accent, in: storage, range: r) }
            case .strong:
                setFont(storage, r) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            case .emphasis:
                setFont(storage, r) {
                    NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask)
                }
            case .strikethrough:
                storage.addAttributes(
                    [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .qnForegroundRole: ForegroundRole.fixed,
                    ], range: r)
            case .inlineCode:
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: baseSize * 0.93, weight: .regular),
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                    ], range: r)
            case .codeBlock:
                let codePara = NSMutableParagraphStyle()
                codePara.lineHeightMultiple = visual ? 1.18 : 1.10
                codePara.paragraphSpacing = 0
                codePara.paragraphSpacingBefore = 0
                // Card padding plus a hanging indent so wrapped lines read as continuations.
                let lineNumbers = codeLineNumbers.contains(span.range.location)
                codePara.firstLineHeadIndent = lineNumbers ? 34 : 4
                codePara.headIndent = lineNumbers ? 48 : 20
                codePara.tailIndent = -4
                codePara.lineBreakMode = .byWordWrapping
                storage.addAttributes(
                    [
                        .font: parent.codeFont,
                        .paragraphStyle: codePara,
                    ], range: r)
                let text = storage.string as NSString
                let firstLine = text.lineRange(for: NSRange(location: r.location, length: 0))
                let lastLine = text.lineRange(
                    for: NSRange(location: NSMaxRange(r) - 1, length: 0))
                let firstParagraph = codePara.mutableCopy() as! NSMutableParagraphStyle
                firstParagraph.paragraphSpacingBefore = 6
                if !span.syntax.isEmpty { firstParagraph.minimumLineHeight = 26 }
                if firstLine == lastLine { firstParagraph.paragraphSpacing = 6 }
                storage.addAttribute(.paragraphStyle, value: firstParagraph, range: firstLine)
                if firstLine != lastLine {
                    let lastParagraph = codePara.mutableCopy() as! NSMutableParagraphStyle
                    lastParagraph.paragraphSpacing = 6
                    storage.addAttribute(.paragraphStyle, value: lastParagraph, range: lastLine)
                }
                let tokens: [CodeToken]
                if let cached = cachedCodeTokens[r.location] {
                    tokens = cached
                } else {
                    tokens = CodeHighlighter.highlight(in: storage.string, span: span)
                    cachedCodeTokens[r.location] = tokens
                }
                let isDark = parent.textColor.luminance > 0.5
                for token in tokens where NSMaxRange(token.range) <= storage.length {
                    let color = Self.tokenColor(token.kind, isDark: isDark)
                    setColor(color, role: .token(token.kind), in: storage, range: token.range)
                }
            case .link(let dest):
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: accent, .qnForegroundRole: ForegroundRole.fixed,
                ]
                if visual { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if let dest, let url = URL(string: dest) { attrs[.toolTip] = url.absoluteString }
                storage.addAttributes(attrs, range: r)
            case .image:
                setColor(.secondaryLabelColor, in: storage, range: r)
                if visual, let image = localImage(for: span), let tv = textView {
                    let maxWidth = max(100, tv.bounds.width - 40)
                    let ratio = min(
                        maxWidth / max(image.size.width, 1), 240 / max(image.size.height, 1), 1)
                    let paragraph = NSMutableParagraphStyle()
                    let line = (storage.string as NSString).lineRange(for: r)
                    if line.location < storage.length {
                        paragraph.setParagraphStyle(
                            storage.attribute(
                                .paragraphStyle, at: line.location, effectiveRange: nil)
                                as? NSParagraphStyle ?? .default)
                        paragraph.paragraphSpacingBefore = image.size.height * ratio + 12
                        storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
                    }
                }
            case .blockQuote:
                let p = NSMutableParagraphStyle()
                p.setParagraphStyle((base[.paragraphStyle] as? NSParagraphStyle) ?? .default)
                if visual {
                    p.headIndent = 12
                    p.firstLineHeadIndent = 12
                    if let marker = span.syntax.first {
                        let width = ((storage.string as NSString).substring(with: marker) as NSString)
                            .size(withAttributes: [.font: baseFont()]).width
                        p.headIndent += width
                    }
                }
                storage.addAttributes(
                    [
                        .foregroundColor: parent.textColor, .paragraphStyle: p,
                        .qnForegroundRole: ForegroundRole.body,
                    ], range: r)
            case .listMarker:
                setColor(accent, in: storage, range: r)
            case .checkbox(let checked):
                storage.addAttributes(
                    [
                        .foregroundColor: checked ? NSColor.secondaryLabelColor : accent,
                        .qnForegroundRole: ForegroundRole.fixed,
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .semibold),
                    ], range: r)
            case .tableHeader:
                storage.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: baseSize * 0.93, weight: .semibold),
                    range: r)
            case .tableRow:
                storage.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: baseSize * 0.93, weight: .regular),
                    range: r)
            case .thematicBreak:
                setColor(.tertiaryLabelColor, in: storage, range: r)
            }
        }

        /// Applies `transform` to each font run in `range`, so nested styles (bold inside a heading) compose.
        private func setFont(
            _ storage: NSTextStorage, _ range: NSRange, _ transform: (NSFont) -> NSFont
        ) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                storage.addAttribute(.font, value: transform(font), range: sub)
            }
        }

        private static func tokenColor(_ kind: CodeToken.Kind, isDark: Bool) -> NSColor {
            if isDark {
                switch kind {
                case .keyword: return NSColor(srgbRed: 0.42, green: 0.80, blue: 0.93, alpha: 1.0)
                case .command: return NSColor(srgbRed: 0.40, green: 0.78, blue: 1.00, alpha: 1.0)
                case .string: return NSColor(srgbRed: 0.98, green: 0.68, blue: 0.45, alpha: 1.0)
                case .comment: return NSColor(srgbRed: 0.55, green: 0.60, blue: 0.65, alpha: 1.0)
                case .number: return NSColor(srgbRed: 0.80, green: 0.88, blue: 0.55, alpha: 1.0)
                case .variable: return NSColor(srgbRed: 0.85, green: 0.62, blue: 1.00, alpha: 1.0)
                case .type: return NSColor(srgbRed: 0.68, green: 0.82, blue: 0.43, alpha: 1.0)
                case .property: return NSColor(srgbRed: 0.40, green: 0.78, blue: 1.00, alpha: 1.0)
                case .tag: return NSColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 1.0)
                }
            } else {
                switch kind {
                case .keyword: return NSColor(srgbRed: 0.05, green: 0.36, blue: 0.58, alpha: 1.0)
                case .command: return NSColor(srgbRed: 0.10, green: 0.42, blue: 0.78, alpha: 1.0)
                case .string: return NSColor(srgbRed: 0.75, green: 0.28, blue: 0.10, alpha: 1.0)
                case .comment: return NSColor(srgbRed: 0.45, green: 0.50, blue: 0.55, alpha: 1.0)
                case .number: return NSColor(srgbRed: 0.12, green: 0.55, blue: 0.25, alpha: 1.0)
                case .variable: return NSColor(srgbRed: 0.50, green: 0.20, blue: 0.75, alpha: 1.0)
                case .type: return NSColor(srgbRed: 0.28, green: 0.44, blue: 0.10, alpha: 1.0)
                case .property: return NSColor(srgbRed: 0.18, green: 0.38, blue: 0.68, alpha: 1.0)
                case .tag: return NSColor(srgbRed: 0.70, green: 0.15, blue: 0.35, alpha: 1.0)
                }
            }
        }
    }
}

struct EditorPasteNotice {
    let hasFormatting: Bool
    let tagCount: Int
    let keepFormatting: () -> Void
    let convertTags: () -> Void
}

// MARK: - Text view

final class MarkdownTextView: NSTextView {
    weak var coordinator: MarkdownEditor.Coordinator?

    private struct CodeCard {
        let span: MarkdownSpan
        let rect: NSRect
    }

    private struct SlashMenuState {
        enum Kind { case command, tag }
        let kind: Kind
        let location: Int
        var query = ""
        var selectedIndex = 0
    }

    private enum MenuChoice {
        case command(MarkdownEditing.SlashCommand)
        case tag(String)

        var title: String {
            switch self {
            case .command(let command): command.title
            case .tag(let tag): "#\(tag)"
            }
        }
    }

    private var hoverArea: NSTrackingArea?
    private var hoveredBlock: Int?
    private var copiedBlock: Int?
    private var cachedCodeCards: [CodeCard]?
    private var cachedQuoteBars: [NSRect]?
    private var copySymbol = ""
    private var slashMenu: SlashMenuState?
    private weak var observedWindow: NSWindow?
    private var resignKeyObserver: NSObjectProtocol?
    private var checkboxButtons: [Int: NSButton] = [:]
    private lazy var copyButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")!,
            target: self, action: #selector(copyHoveredCode(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.toolTip = "Copy code"
        button.setAccessibilityLabel("Copy code")
        button.isHidden = true
        addSubview(button)
        return button
    }()

    override func draw(_ dirtyRect: NSRect) {
        updateCheckboxButtons()
        let cards = codeCards()
        drawCodeBackgrounds(cards, in: dirtyRect)
        super.draw(dirtyRect)
        drawQuoteBars(in: dirtyRect)
        drawCodeControls(cards)
        drawThematicBreaks()
        drawImagePreviews()
        drawSlashMenu()
    }

    override func layout() {
        super.layout()
        updateCheckboxButtons()
        updateCopyButton(codeCards())
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateCodeCards() }
    }

    func invalidateCodeCards() {
        cachedCodeCards = nil
        cachedQuoteBars = nil
    }

    private func updateCheckboxButtons() {
        guard let coordinator, coordinator.isVisual, let layoutManager, let textContainer else {
            for button in checkboxButtons.values { button.removeFromSuperview() }
            checkboxButtons.removeAll()
            return
        }
        let text = string as NSString
        let origin = textContainerOrigin
        var locations = Set<Int>()
        for span in coordinator.checkboxSpans where NSMaxRange(span.range) <= text.length {
            guard case .checkbox(let checked) = span.kind else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            let marker = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let frame = NSRect(x: marker.minX + origin.x, y: marker.midY + origin.y - 9, width: 18, height: 18)
            guard frame.intersects(visibleRect) else { continue }
            let location = span.range.location
            locations.insert(location)
            let button: NSButton
            if let existing = checkboxButtons[location] {
                button = existing
            } else {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheckbox(_:)))
                button.controlSize = .small
                button.tag = location
                checkboxButtons[location] = button
                addSubview(button)
            }
            button.frame = frame
            button.state = checked ? .on : .off
            let line = text.lineRange(for: span.range)
            let label = text.substring(with: NSRange(location: NSMaxRange(span.range), length: NSMaxRange(line) - NSMaxRange(span.range)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            button.setAccessibilityLabel(label.isEmpty ? "Task" : label)
            button.toolTip = checked ? "Mark incomplete" : "Mark complete"
        }
        for location in Array(checkboxButtons.keys) where !locations.contains(location) {
            checkboxButtons.removeValue(forKey: location)?.removeFromSuperview()
        }
    }

    @objc private func toggleCheckbox(_ button: NSButton) {
        guard coordinator?.isVisual == true,
            MarkdownAnalyzer.togglingCheckbox(in: string, at: button.tag) != nil
        else { return }
        let range = NSRange(location: button.tag, length: 3)
        let marker = (string as NSString).substring(with: range)
        apply(TextEdit(range: range, replacement: marker == "[ ]" ? "[x]" : "[ ]", selection: selectedRange()))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        observedWindow = window
        resignKeyObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.coordinator?.setPeekRaw(false)
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        coordinator?.setPeekRaw(event.modifierFlags.contains(.option))
        super.flagsChanged(with: event)
    }

    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }

    // MARK: Code cards

    /// One rounded card per fenced/indented block, spanning every line including blank and hidden fence lines.
    private func codeCards() -> [CodeCard] {
        if let cachedCodeCards { return cachedCodeCards }
        guard let lm = layoutManager, let coord = coordinator else { return [] }
        let textLength = (string as NSString).length
        let origin = textContainerOrigin
        var cards: [CodeCard] = []
        for span in coord.codeBlockSpans where NSMaxRange(span.range) <= textLength {
            let glyphRange = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            var union: NSRect?
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                union = union.map { $0.union(usedRect) } ?? usedRect
            }
            guard let block = union else { continue }
            let rect = NSRect(
                x: 8, y: block.minY + origin.y - 3, width: max(bounds.width - 16, 40),
                height: block.height + 6)
            cards.append(CodeCard(span: span, rect: rect))
        }
        cachedCodeCards = cards
        return cards
    }

    private func isFocused(_ span: MarkdownSpan) -> Bool {
        let sel = selectedRange()
        return window?.firstResponder === self
            && MarkdownEditing.selection(sel, touches: span.range)
    }

    private func controlsVisible(_ card: CodeCard) -> Bool {
        guard let coord = coordinator, coord.isVisual, card.rect.width > 80
        else { return false }
        return hoveredBlock == card.span.range.location
    }

    /// Controls sit on the fence line, which keeps its height even while the fence text is hidden.
    private func copyControlRect(for card: CodeCard) -> NSRect {
        NSRect(x: card.rect.maxX - 30, y: card.rect.minY + 4, width: 24, height: 24)
    }

    private func drawCodeBackgrounds(_ cards: [CodeCard], in dirtyRect: NSRect) {
        guard let coord = coordinator else { return }
        let isDark = coord.appliedTextColor.luminance > 0.5
        let fill =
            isDark
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.045)
        let border =
            isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)
        for card in cards where card.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: card.rect, xRadius: 6, yRadius: 6)
            fill.setFill()
            path.fill()
            let focused = isFocused(card.span)
            (focused ? NSColor.controlAccentColor.withAlphaComponent(0.55) : border).setStroke()
            path.lineWidth = focused ? 1.5 : 1
            path.stroke()
        }
    }

    private func updateCopyButton(_ cards: [CodeCard]) {
        let hoveredCard = cards.first(where: controlsVisible)
        let hidden = hoveredCard == nil
        if copyButton.isHidden != hidden { copyButton.isHidden = hidden }
        if let hoveredCard {
            let frame = copyControlRect(for: hoveredCard)
            if copyButton.frame != frame { copyButton.frame = frame }
            let symbol = copiedBlock == hoveredCard.span.range.location
                ? "checkmark" : "doc.on.doc"
            if copySymbol != symbol {
                copyButton.image = NSImage(
                    systemSymbolName: symbol, accessibilityDescription: "Copy code")
                copySymbol = symbol
            }
        }
    }

    private func drawCodeControls(_ cards: [CodeCard]) {
        guard let coord = coordinator else { return }
        let isDark = coord.appliedTextColor.luminance > 0.5
        let ink =
            isDark ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.7)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for card in cards where coord.showsLineNumbers(at: card.span.range.location) {
            guard let range = CodeHighlighter.codeRange(in: string, span: card.span) else {
                continue
            }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var number = 1
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                let text = String(number)
                number += 1
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: coord.parent.codeFont.withSize(max(10, coord.parent.codeFont.pointSize - 2)),
                    .foregroundColor: ink.withAlphaComponent(0.55),
                ]
                (text as NSString).draw(
                    at: NSPoint(
                        x: card.rect.minX + 8,
                        y: rect.minY + origin.y + 3),
                    withAttributes: attrs)
            }
        }
    }

    private func drawImagePreviews() {
        guard let layoutManager, let textContainer, let coordinator else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        for span in coordinator.imageSpans where NSMaxRange(span.range) <= ns.length {
            guard let image = coordinator.localImage(for: span) else { continue }
            let line = ns.lineRange(for: span.range)
            guard !MarkdownEditing.selection(selectedRange(), touches: line) else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: line, actualCharacterRange: nil)
            var lineRect: NSRect?
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                lineRect = lineRect.map { $0.union(rect) } ?? rect
            }
            guard let lineRect else { continue }
            let maximum = max(80, bounds.width - 36)
            let scale = min(maximum / max(image.size.width, 1), 240 / max(image.size.height, 1), 1)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(
                x: max(16, origin.x + lineRect.minX),
                y: origin.y + lineRect.minY - size.height - 8,
                width: size.width, height: size.height)
            guard rect.intersects(bounds) else { continue }
            let backing = NSBezierPath(
                roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            backing.fill()
            image.draw(in: rect)
        }
    }

    private func drawQuoteBars(in dirtyRect: NSRect) {
        guard let coordinator, coordinator.isVisual, let layoutManager, let textContainer else { return }
        if cachedQuoteBars == nil {
            let quotes = coordinator.blockQuoteSpans
            let origin = textContainerOrigin
            var bars: [NSRect] = []
            for span in quotes where NSMaxRange(span.range) <= (string as NSString).length {
                let glyphs = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
                var block = NSRect.null
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                    block = block.union(usedRect)
                }
                guard !block.isNull else { continue }
                let depth = quotes.filter {
                    $0.range != span.range && $0.range.location <= span.range.location
                        && NSMaxRange($0.range) >= NSMaxRange(span.range)
                }.count
                bars.append(NSRect(
                    x: origin.x + 4 + CGFloat(depth) * 14,
                    y: origin.y + block.minY + 1, width: 3,
                    height: max(4, block.height - 2)))
            }
            cachedQuoteBars = bars
        }
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        for rect in cachedQuoteBars ?? [] where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawThematicBreaks() {
        guard coordinator?.isVisual == true, let layoutManager, let textContainer, let coordinator
        else { return }
        let origin = textContainerOrigin
        for span in coordinator.thematicBreakSpans
        where NSMaxRange(span.range) <= (string as NSString).length {
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: span.range, actualCharacterRange: nil)
            var lineRect: NSRect?
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                lineRect = lineRect.map { $0.union(rect) } ?? rect
            }
            guard let lineRect else { continue }
            let y = origin.y + lineRect.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: origin.x, y: y))
            path.line(to: NSPoint(x: max(origin.x + 1, bounds.maxX - origin.x), y: y))
            NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        setHovered(codeCards().first { $0.rect.contains(point) }?.span.range.location)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    private func setHovered(_ block: Int?) {
        guard block != hoveredBlock else { return }
        hoveredBlock = block
        updateCopyButton(codeCards())
        needsDisplay = true
    }

    private func handleCodeControlClick(at point: NSPoint) -> Bool {
        for card in codeCards() where controlsVisible(card) {
            if copyControlRect(for: card).contains(point) {
                copyCode(card.span)
                return true
            }
        }
        return false
    }

    private func slashMenuRect() -> NSRect? {
        guard slashMenu != nil, let layoutManager, let textContainer else { return nil }
        guard !menuChoices().isEmpty else { return nil }
        let rowHeight: CGFloat = 24
        let menuHeight = CGFloat(menuChoices().count) * rowHeight + 10
        let selection = selectedRange()
        let character = max(
            0,
            min(
                selection.location == 0 ? 0 : selection.location - 1,
                (string as NSString).length - 1))
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
        let line = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(
            dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let x = min(max(8, line.minX), max(8, bounds.width - 228))
        let y = min(max(8, line.minY - menuHeight - 5), max(8, bounds.height - menuHeight - 8))
        return NSRect(x: x, y: y, width: 220, height: menuHeight)
    }

    private func drawSlashMenu() {
        guard let state = slashMenu, let rect = slashMenuRect() else { return }
        let commands = menuChoices()
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        for (index, command) in commands.enumerated() {
            let row = NSRect(
                x: rect.minX + 5, y: rect.maxY - 29 - CGFloat(index) * 24, width: rect.width - 10,
                height: 22)
            if index == state.selectedIndex {
                let highlight = NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4)
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                highlight.fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
            (command.title as NSString).draw(
                at: NSPoint(x: row.minX + 8, y: row.minY + 4), withAttributes: attrs)
        }
    }

    private func handleSlashMenuClick(at point: NSPoint) -> Bool {
        guard let rect = slashMenuRect(), rect.contains(point), let state = slashMenu else {
            return false
        }
        let row = Int((rect.maxY - point.y - 5) / 24)
        let commands = menuChoices()
        guard commands.indices.contains(row) else { return true }
        selectMenuChoice(commands[row])
        return true
    }

    private func menuChoices() -> [MenuChoice] {
        guard let state = slashMenu else { return [] }
        switch state.kind {
        case .command:
            return MarkdownEditing.slashCommands(matching: state.query).map(MenuChoice.command)
        case .tag:
            return coordinator?.parent.labels
                .filter {
                    state.query.isEmpty
                        || $0.localizedLowercase.hasPrefix(state.query.localizedLowercase)
                }
                .map(MenuChoice.tag) ?? []
        }
    }

    private func selectMenuChoice(_ choice: MenuChoice) {
        guard let state = slashMenu else { return }
        let caret = selectedRange().location
        let range = NSRange(location: state.location, length: max(0, caret - state.location))
        let replacement: String
        let caretOffset: Int
        var chooseImage = false
        switch choice {
        case .command(let command):
            switch command {
            case .code:
                replacement = "```\n\n```"
                caretOffset = ("```\n" as NSString).length
            case .checklist:
                replacement = "- [ ] "
                caretOffset = (replacement as NSString).length
            case .heading:
                replacement = "# "
                caretOffset = (replacement as NSString).length
            case .divider:
                replacement = "---\n\n"
                caretOffset = (replacement as NSString).length
            case .today:
                replacement = Date.now.formatted(date: .abbreviated, time: .omitted)
                caretOffset = (replacement as NSString).length
            case .image:
                replacement = ""
                caretOffset = 0
                chooseImage = true
            }
        case .tag(let tag):
            replacement = ""
            caretOffset = 0
            let count = coordinator?.parent.onAddTags([tag]) ?? 0
            if count > 0 { coordinator?.parent.onTagsAdded(count) }
        }

        slashMenu = nil
        apply(
            TextEdit(
                range: range, replacement: replacement,
                selection: NSRange(location: range.location + caretOffset, length: 0)))
        if chooseImage {
            let insertion = selectedRange().location
            coordinator?.parent.onChooseImage { [weak self] data in
                self?.insertImage(data, at: insertion)
            }
        }
        needsDisplay = true
    }

    private func copyCode(_ span: MarkdownSpan) {
        guard let range = CodeHighlighter.codeRange(in: string, span: span) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            (string as NSString).substring(with: range), forType: .string)
        copiedBlock = span.range.location
        coordinator?.parent.onCopy()
        updateCopyButton(codeCards())
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copiedBlock = nil
            if let self { self.updateCopyButton(self.codeCards()) }
            self?.needsDisplay = true
        }
    }

    @objc private func copyHoveredCode(_ sender: NSButton) {
        guard let span = coordinator?.codeBlockSpans.first(where: {
            $0.range.location == hoveredBlock
        }) else { return }
        copyCode(span)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let card = codeCards().first(where: { $0.rect.contains(point) }) else {
            return super.menu(for: event)
        }
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let raw = NSMenuItem(
            title: coordinator?.isRawCodeBlock(at: card.span.range.location) == true
                ? "Show Formatted Code" : "Show Raw Markdown",
            action: #selector(toggleRawCodeBlock(_:)), keyEquivalent: "")
        raw.target = self
        raw.tag = card.span.range.location
        raw.state = coordinator?.isRawCodeBlock(at: card.span.range.location) == true ? .on : .off
        menu.addItem(raw)
        menu.addItem(.separator())
        let numbers = NSMenuItem(
            title: "Line Numbers", action: #selector(toggleLineNumbers(_:)), keyEquivalent: "")
        numbers.target = self
        numbers.tag = card.span.range.location
        numbers.state =
            coordinator?.showsLineNumbers(at: card.span.range.location) == true ? .on : .off
        menu.addItem(numbers)
        return menu
    }

    @objc private func toggleRawCodeBlock(_ item: NSMenuItem) {
        coordinator?.toggleRawCodeBlock(at: item.tag)
        needsDisplay = true
    }

    @objc private func toggleLineNumbers(_ item: NSMenuItem) {
        coordinator?.toggleCodeLineNumbers(at: item.tag)
        needsDisplay = true
    }

    /// Applies an edit through the normal text-system path so undo and change notifications work.
    func apply(_ edit: TextEdit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let imageData = imageData(from: pasteboard) {
            let selection = selectedRange()
            guard !isInsideCodeBlock(at: selection.location) else { return }
            let insertion = imageInsertionLocation(after: NSMaxRange(selection))
            insertImage(imageData, at: insertion)
            return
        }
        guard let plainText = pasteboard.string(forType: .string) else {
            pasteAsPlainText(sender)
            return
        }
        let selection = selectedRange()
        let pasteRange = NSRange(
            location: selection.location, length: (plainText as NSString).length)
        let rich =
            pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first
            as? NSAttributedString
        let hasFormatting =
            pasteboard.types?.contains {
                ["public.rtf", "public.html", "com.apple.flat-rtfd"].contains($0.rawValue)
            } ?? false
        let formattedText = hasFormatting ? rich.map(Self.markdown(from:)) : nil
        let extracted = LabelNormalizer.extractingHashtags(from: plainText)
        let insideCode = isInsideCodeBlock(at: selection.location)
        pasteAsPlainText(sender)
        guard !insideCode, hasFormatting || !extracted.labels.isEmpty else { return }

        let keepFormatting: () -> Void = { [weak self] in
            guard let self, let formattedText else { return }
            self.apply(
                TextEdit(
                    range: pasteRange, replacement: formattedText,
                    selection: NSRange(
                        location: pasteRange.location + (formattedText as NSString).length,
                        length: 0)))
        }
        let convertTags: () -> Void = { [weak self] in
            guard let self else { return }
            self.apply(
                TextEdit(
                    range: pasteRange, replacement: extracted.text,
                    selection: NSRange(
                        location: pasteRange.location + (extracted.text as NSString).length,
                        length: 0)))
            let count = self.coordinator?.parent.onAddTags(extracted.labels) ?? 0
            if count > 0 { self.coordinator?.parent.onTagsAdded(count) }
        }
        coordinator?.parent.onPasteNotice(
            EditorPasteNotice(
                hasFormatting: hasFormatting && formattedText != nil,
                tagCount: extracted.labels.count,
                keepFormatting: keepFormatting,
                convertTags: convertTags))
    }

    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        let candidates = [
            NSPasteboard.PasteboardType.png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.gif"),
            NSPasteboard.PasteboardType("public.bmp"),
        ]
        for type in candidates {
            if let data = pasteboard.data(forType: type), let png = Self.pngData(from: data) {
                return png
            }
        }
        for type in pasteboard.types ?? [] where type.rawValue.localizedLowercase.contains("image")
        {
            if let data = pasteboard.data(forType: type), let png = Self.pngData(from: data) {
                return png
            }
        }
        let images =
            pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.compactMap {
                $0 as? NSImage
            } ?? []
        for image in images {
            if let data = image.tiffRepresentation, let png = Self.pngData(from: data) {
                return png
            }
        }
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.compactMap {
                $0 as? URL
            } ?? []
        for url in urls where url.isFileURL {
            if let image = NSImage(contentsOf: url), let data = image.tiffRepresentation,
                let png = Self.pngData(from: data)
            {
                return png
            }
        }
        return nil
    }

    private static func pngData(from data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func insertImage(_ data: Data, at requestedLocation: Int) {
        guard let png = Self.pngData(from: data), !isInsideCodeBlock(at: requestedLocation) else {
            return
        }
        coordinator?.parent.onPasteImage(png) { [weak self] path in
            guard let self else { return }
            let insertion = min(max(0, requestedLocation), (self.string as NSString).length)
            let markdown = "![Image](\(path))"
            self.apply(
                TextEdit(
                    range: NSRange(location: insertion, length: 0), replacement: markdown,
                    selection: NSRange(
                        location: insertion + (markdown as NSString).length, length: 0)))
            self.coordinator?.parent.onImageAdded()
        }
    }

    private func imageInsertionLocation(after location: Int) -> Int {
        let ns = string as NSString
        let start = min(max(0, location), ns.length)
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        let end = NSMaxRange(line)
        guard start < end else { return start }
        let range = ns.range(
            of: " ", options: [], range: NSRange(location: start, length: end - start))
        return range.location == NSNotFound ? end : range.location
    }

    private static func markdown(from attributed: NSAttributedString) -> String {
        var output = ""
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
            attributes, range, _ in
            var value = attributed.attributedSubstring(from: range).string
            if let link = attributes[.link] as? URL {
                value = "[\(value)](\(link.absoluteString))"
            } else if let link = attributes[.link] as? String {
                value = "[\(value)](\(link))"
            }
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { value = "**\(value)**" }
                if traits.contains(.italicFontMask) { value = "*\(value)*" }
            }
            output += value
        }
        return output
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let typed = insertString as? String,
            !hasMarkedText()
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if let menu = slashMenu {
            super.insertText(insertString, replacementRange: replacementRange)
            if typed == " " || typed == "\n" || typed == "\r" {
                slashMenu = nil
            } else if (typed as NSString).length == 1 {
                slashMenu?.query.append(typed)
                slashMenu?.selectedIndex = 0
            }
            needsDisplay = true
            return
        }
        guard (typed as NSString).length == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        if typed == "/", isAtSlashBoundary(selection.location),
            !isInsideCodeBlock(at: selection.location)
        {
            super.insertText(insertString, replacementRange: replacementRange)
            slashMenu = SlashMenuState(kind: .command, location: selection.location)
            needsDisplay = true
            return
        }
        if typed == "#", isAtSlashBoundary(selection.location),
            !isInsideCodeBlock(at: selection.location)
        {
            super.insertText(insertString, replacementRange: replacementRange)
            slashMenu = SlashMenuState(kind: .tag, location: selection.location)
            needsDisplay = true
            return
        }
        if let edit = MarkdownEditing.completeCodeFence(
            in: string, selection: selection, typed: typed)
        {
            apply(edit)
            return
        }
        if let next = MarkdownEditing.closingCharacterSelection(
            in: string, selection: selection, typed: typed)
        {
            setSelectedRange(next)
            return
        }
        if let edit = MarkdownEditing.autoPair(in: string, selection: selection, typed: typed) {
            apply(edit)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        guard var state = slashMenu else {
            super.deleteBackward(sender)
            return
        }
        let selection = selectedRange()
        guard selection.length == 0, selection.location > state.location + 1 else {
            slashMenu = nil
            super.deleteBackward(sender)
            needsDisplay = true
            return
        }
        super.deleteBackward(sender)
        let start = state.location + 1
        let caret = selectedRange().location
        state.query = (string as NSString).substring(
            with: NSRange(location: start, length: max(0, caret - start)))
        state.selectedIndex = 0
        slashMenu = state
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard var state = slashMenu else {
            super.keyDown(with: event)
            return
        }
        let commands = menuChoices()
        switch event.keyCode {
        case 53:
            slashMenu = nil
            needsDisplay = true
        case 125, 126:
            if !commands.isEmpty {
                let delta = event.keyCode == 125 ? 1 : -1
                state.selectedIndex =
                    (state.selectedIndex + delta + commands.count) % commands.count
                slashMenu = state
                needsDisplay = true
            }
        case 36, 76:
            if commands.indices.contains(state.selectedIndex) {
                selectMenuChoice(commands[state.selectedIndex])
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func isAtSlashBoundary(_ location: Int) -> Bool {
        guard location > 0 else { return true }
        let ns = string as NSString
        guard location <= ns.length else { return false }
        let previous = ns.character(at: location - 1)
        return previous == 0x20 || previous == 0x09 || previous == 0x0A || previous == 0x0D
    }

    private func isInsideCodeBlock(at location: Int) -> Bool {
        coordinator?.codeBlockSpans.contains { span in
            guard let range = CodeHighlighter.codeRange(in: string, span: span) else {
                return false
            }
            return location >= range.location && location < NSMaxRange(range)
        } ?? false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleSlashMenuClick(at: point) { return }
        if handleCodeControlClick(at: point) { return }
        if let lm = layoutManager, let tc = textContainer {
            let origin = textContainerOrigin
            let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            let idx = lm.characterIndex(
                for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            MainActor.assumeIsolated {
                if event.modifierFlags.contains(.command),
                    let url = coordinator?.linkDestination(at: idx)
                {
                    NSWorkspace.shared.open(url)
                    return
                }
                super.mouseDown(with: event)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, key.lowercased() == "f" {
            coordinator?.parent.onFind()
            return true
        }
        if modifiers == .command || modifiers == .control,
            ["\r", "\n", "\u{3}"].contains(key),
            let edit = MarkdownEditing.escapeCodeBlock(in: string, selection: selectedRange())
        {
            apply(edit)
            return true
        }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b":
            apply(MarkdownEditing.toggleWrap(in: string, selection: selectedRange(), marker: "**"))
            return true
        case "i":
            apply(MarkdownEditing.toggleWrap(in: string, selection: selectedRange(), marker: "*"))
            return true
        case "e":
            apply(MarkdownEditing.toggleWrap(in: string, selection: selectedRange(), marker: "`"))
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
