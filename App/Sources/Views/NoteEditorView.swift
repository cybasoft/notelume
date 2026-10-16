import NoteLumeCore
import SwiftUI
import UniformTypeIdentifiers

/// The note editing surface used in every note window (sticky or regular).
struct NoteEditorView: View {
    @Bindable var session: NoteEditSession
    let model: AppModel
    let windowState: NoteWindowState
    let setAlwaysOnTop: (Bool) -> Void

    @State private var showLabels = false
    @State private var showAppearance = false
    @State private var showReminder = false
    @State private var showReminderDatePicker = false
    @State private var showHistory = false
    @State private var showFindBar = false
    @State private var findQuery = ""
    @State private var findRequest = 0
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var isRawViewActive = false
    @State private var pasteNotice: EditorPasteNotice?
    @State private var isTyping = false
    @State private var typingTask: Task<Void, Never>?
    @State private var toast: EditorToast?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool
    @FocusState private var findFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meta: NoteMetadata { session.document.metadata }
    private var background: NSColor? { NSColor(hex: meta.color) }
    private var textColor: NSColor {
        NoteAppearance.text(textHex: meta.textColor, backgroundHex: meta.color)
    }
    private var opacity: Double { meta.opacity ?? 1 }
    private var mode: EditorMode { meta.markdown ? .visual : .source }

    var body: some View {
        VStack(spacing: 0) {
            banners
            labelBar
            titleField
            if showFindBar { findBar }
            MarkdownEditor(
                text: session.document.body,
                revision: session.revision,
                mode: mode,
                textColor: textColor,
                codeFont: CodeFont.font(
                    family: model.settings?.codeFontFamily ?? "",
                    size: model.settings?.codeFontSize ?? 13),
                labels: model.labelCounts.map(\.label),
                notesDirectory: model.store?.notesDirectory,
                searchQuery: showFindBar ? findQuery : "",
                searchRequest: findRequest,
                onChange: {
                    session.setBody($0)
                    pasteNotice = nil
                    typingTask?.cancel()
                    isTyping = true
                    typingTask = Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        guard !Task.isCancelled else { return }
                        isTyping = false
                    }
                },
                onAddTags: addTags,
                onTagsAdded: { showToast("\($0) tags added") },
                onRawModeChange: { isRawViewActive = $0 },
                onCopy: { showToast("Copied") },
                onPasteNotice: { pasteNotice = $0 },
                onPasteImage: { data, complete in
                    Task { @MainActor in
                        do {
                            guard let store = model.store,
                                let path = try await store.storeMediaImage(
                                    data, for: session.noteID)
                            else { return }
                            complete(path)
                        } catch {
                            model.lastError = error.localizedDescription
                        }
                    }
                },
                onChooseImage: { complete in
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic, .bmp]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        guard response == .OK, let url = panel.url,
                            let image = NSImage(contentsOf: url),
                            let tiff = image.tiffRepresentation,
                            let bitmap = NSBitmapImageRep(data: tiff),
                            let png = bitmap.representation(using: .png, properties: [:])
                        else { return }
                        complete(png)
                    }
                },
                onImageAdded: { showToast("Image added") },
                onFind: {
                    showFindBar = true
                    DispatchQueue.main.async { findFocused = true }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            pasteNoticeView
            toastView
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            (background.map { Color(nsColor: $0) } ?? Color(nsColor: .windowBackgroundColor))
                .opacity(opacity)
                .ignoresSafeArea()
        }
        .background(WindowTitle(title: session.document.displayTitle).allowsHitTesting(false))
        .onChange(of: titleFocused) { _, focused in
            if focused { editingTitle = true } else if meta.title == nil { editingTitle = false }
        }
        .onAppear { isRawViewActive = mode == .source }
        .environment(
            \.colorScheme,
            background == nil
                ? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light)
                : (background!.luminance > 0.55 ? .light : .dark)
        )
        .sheet(isPresented: $showHistory) { HistoryView(model: model, session: session) }
        .onDisappear {
            typingTask?.cancel()
            toastTask?.cancel()
        }
    }

    // MARK: Title

    @ViewBuilder private var titleField: some View {
        if meta.title != nil || editingTitle {
            HStack(spacing: 8) {
                colorDot
                TextField(
                    "Title",
                    text: Binding(
                        get: { meta.title ?? titleDraft },
                        set: { new in
                            let cleaned = new.replacingOccurrences(of: "\n", with: " ")
                            titleDraft = cleaned
                            let title =
                                cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cleaned
                            session.updateMetadata { $0.title = title }
                            if title == nil {
                                editingTitle = false
                                titleFocused = false
                            }
                        }), axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1...4)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color(nsColor: textColor))
                .help("Title. Clear it to go back to the first line of the note.")
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 2)
        } else {
            Button(action: beginEditingTitle) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    colorDot
                    Text(session.document.displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(nsColor: textColor))
                    Text("auto")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: textColor).opacity(0.48))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 2)
            .help("Derived from the first line. Click to set a title.")
            .accessibilityLabel("\(session.document.displayTitle), automatic title. Edit title")
        }
    }

    private func beginEditingTitle() {
        titleDraft = meta.title ?? session.document.displayTitle
        editingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            TextField("Find in note", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { findRequest += 1 }
                .accessibilityLabel("Find in note")
            Text("\(findMatchCount) matches").font(.caption).foregroundStyle(.secondary)
            Button {
                findRequest -= 1
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain).help("Previous match").accessibilityLabel("Previous match")
            .disabled(findMatchCount == 0)
            Button {
                findRequest += 1
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain).help("Next match").accessibilityLabel("Next match")
            .disabled(findMatchCount == 0)
            Button(action: closeFind) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close find").accessibilityLabel("Close find")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var findMatchCount: Int {
        MarkdownEditing.searchMatches(in: session.document.body, query: findQuery).count
    }

    private func closeFind() {
        showFindBar = false
        findQuery = ""
        findFocused = false
    }

    @ViewBuilder private var colorDot: some View {
        if let background {
            Circle().fill(Color(nsColor: background)).frame(width: 7, height: 7)
                .overlay(
                    Circle().strokeBorder(Color(nsColor: textColor).opacity(0.35), lineWidth: 0.5)
                )
                .accessibilityLabel("Note color")
        }
    }

    // MARK: Toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Color(nsColor: textColor).opacity(0.08).frame(height: 1)
            HStack(spacing: 4) {
                statusIndicator.padding(.leading, 4)
                if isRawViewActive {
                    Text("RAW MARKDOWN").font(.system(size: 9, weight: .bold)).foregroundStyle(
                        Color.accentColor)
                }
                Spacer(minLength: 4)
                toolbarButton(
                    meta.sticky ? "pin.fill" : "pin", active: meta.sticky,
                    help: meta.sticky
                        ? "In the Sticky Notes list. Click to remove."
                        : "Pin to the Sticky Notes list"
                ) {
                    let pinned = !meta.sticky
                    session.updateMetadata { $0.sticky = pinned }
                    showToast(pinned ? "Pinned on top" : "Unpinned") {
                        session.updateMetadata { $0.sticky = !pinned }
                    }
                }
                if meta.sticky || windowState.alwaysOnTop {
                    toolbarButton(
                        windowState.alwaysOnTop ? "macwindow.on.rectangle" : "macwindow",
                        active: windowState.alwaysOnTop,
                        help: windowState.alwaysOnTop
                            ? "Always on top (this Mac). Click to turn off."
                            : "Keep this window on top (this Mac)"
                    ) {
                        setAlwaysOnTop(!windowState.alwaysOnTop)
                    }
                }
                toolbarButton("paintpalette", help: "Color and opacity") { showAppearance = true }
                    .popover(isPresented: $showAppearance, arrowEdge: .top) { appearancePopover }
                if let reminder = meta.reminder {
                    Text(reminderText(reminder)).font(.caption2)
                        .foregroundStyle(reminder < Date() ? Color.red : Color.accentColor)
                        .help("Reminder: \(reminder.formatted(date: .complete, time: .shortened))")
                }
                toolbarButton(
                    meta.reminder == nil ? "bell" : "bell.fill", active: meta.reminder != nil,
                    help: meta.reminder == nil ? "Add a reminder" : "Edit reminder"
                ) { showReminder = true }
                .popover(isPresented: $showReminder, arrowEdge: .top) { reminderPopover }
                toolbarButton(
                    isRawViewActive
                        ? "eye.fill"
                        : (mode == .visual ? "eye" : "chevron.left.forwardslash.chevron.right"),
                    active: isRawViewActive,
                    help: isRawViewActive
                        ? "Raw Markdown view. Click for visual editing."
                        : "Visual editing. Click for raw Markdown."
                ) {
                    if !session.document.hasFrontmatter { session.initializeMetadata() }
                    session.updateMetadata { $0.markdown.toggle() }
                }
                .disabled(!session.document.canEditMetadata)
                Menu {
                    Button(meta.title == nil ? "Add Title" : "Edit Title") { beginEditingTitle() }
                    if meta.title != nil {
                        Button("Use First Line as Title") {
                            session.updateMetadata { $0.title = nil }
                            editingTitle = false
                        }
                    }
                    Divider()
                    Button("Version History…") { showHistory = true }
                    Button("Show in Finder") {
                        if let dir = model.folderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                dir.appendingPathComponent(
                                    NoteFileName.filename(for: session.noteID))
                            ])
                        }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.trash(session.noteID) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .foregroundStyle(Color(nsColor: textColor).opacity(0.7))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(background.map { Color(nsColor: $0).opacity(0.2) } ?? Color.clear)
        }
    }

    private func toolbarButton(
        _ symbol: String, active: Bool = false, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(
                    active ? Color.accentColor : Color(nsColor: textColor).opacity(0.7)
                )
                .frame(width: 28, height: 24)
                .background(
                    active ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func reminderText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder private var statusIndicator: some View {
        if isTyping {
            Text("Editing…").font(.caption2).opacity(0.7)
        } else {
            switch session.state {
            case .saving, .dirty:
                Text("Saving…").font(.caption2).opacity(0.7)
            case .clean:
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let updated = session.document.metadata.updated
                    let relativeTime =
                        Date.now.timeIntervalSince(updated) < 60
                        ? "just now"
                        : updated.formatted(.relative(presentation: .named))
                    Text("Saved · \(lineCount) lines · edited \(relativeTime)")
                        .font(.caption2)
                        .opacity(0.7)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Saved, \(lineCount) lines")
                }
            case .conflict, .deletedOnDisk, .failed:
                Text("Not saved").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var lineCount: Int {
        max(1, session.document.body.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    @ViewBuilder private var pasteNoticeView: some View {
        if let pasteNotice {
            HStack(spacing: 8) {
                Text("Pasted as plain text")
                if pasteNotice.hasFormatting {
                    Button("Keep formatting") {
                        pasteNotice.keepFormatting()
                        self.pasteNotice = nil
                    }
                    .buttonStyle(.plain)
                }
                if pasteNotice.tagCount > 0 {
                    Button("Convert #tags to chips") {
                        pasteNotice.convertTags()
                        self.pasteNotice = nil
                    }
                    .buttonStyle(.plain)
                }
                Button("Dismiss") { self.pasteNotice = nil }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss paste options")
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    Color(nsColor: textColor).opacity(0.14))
            )
            .padding(.horizontal, 10).padding(.bottom, 4)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            HStack(spacing: 10) {
                Text(toast.message).font(.caption)
                if let undo = toast.undo {
                    Button(
                        "Undo",
                        action: {
                            undo()
                            dismissToast()
                        }
                    )
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
                Button(action: dismissToast) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: textColor).opacity(0.14)))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.bottom, 4)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    private func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            toast = EditorToast(message: message, undo: undo)
        }
        NSAccessibility.post(
            element: NSApp, notification: .announcementRequested,
            userInfo: [.announcement: message])
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { toast = nil }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        switch session.state {
        case .conflict:
            Banner(
                icon: "arrow.triangle.merge", tint: .orange,
                text:
                    "This note was changed elsewhere while you were editing. Nothing was overwritten."
            ) {
                Button("Keep Both") { Task { _ = try? await session.resolveKeepingBoth() } }
                Button("Keep Mine") { Task { await session.resolveKeepingMine() } }
                Button("Use Theirs") { session.resolveTakingDisk() }
            }
        case .deletedOnDisk:
            Banner(
                icon: "trash.slash", tint: .red,
                text: "This note's file was deleted or moved elsewhere. Your text is still here."
            ) {
                Button("Recreate Note") { Task { await session.recreate() } }
            }
        case .failed(let message):
            Banner(icon: "exclamationmark.octagon", tint: .red, text: "Couldn't save: \(message)") {
                Button("Retry") { Task { await session.retry() } }
            }
        default: EmptyView()
        }

        ForEach(Array(session.document.issues.enumerated()), id: \.offset) { _, issue in
            switch issue {
            case .missingFrontmatter:
                Banner(
                    icon: "doc.badge.gearshape", tint: .blue,
                    text:
                        "This file has no metadata block, so labels, color and reminders can't be saved yet."
                ) {
                    Button("Initialize Metadata") { session.initializeMetadata() }
                }
            case .idMismatch:
                Banner(icon: "number", tint: .yellow, text: issue.message) {
                    Button("Use Filename ID") { session.adoptFilenameID() }
                }
            default:
                Banner(icon: "info.circle", tint: .yellow, text: issue.message) { EmptyView() }
            }
        }
    }

    // MARK: Labels

    private var labelBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(meta.labels, id: \.self) { label in
                    LabelChip(
                        text: label, color: textColor, select: { model.selection = .label(label) }
                    ) {
                        removeLabel(label)
                    }
                }
                Button {
                    showLabels = true
                } label: {
                    Text("+ tag").font(.caption).opacity(0.6)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(
                            Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .opacity(0.35)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add a label")
                .accessibilityLabel("Add a label")
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        }
        .foregroundStyle(Color(nsColor: textColor))
        .popover(isPresented: $showLabels, arrowEdge: .bottom) { labelPopover }
    }

    private var labelPopover: some View {
        LabelPicker(selected: meta.labels, all: model.labelCounts.map(\.label)) { label in
            session.updateMetadata { m in
                if m.labels.contains(label) {
                    m.labels.removeAll { $0 == label }
                } else {
                    m.labels = LabelNormalizer.normalize(m.labels + [label])
                }
            }
        }
    }

    // MARK: Appearance

    private var appearancePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background").font(.headline)
            HStack(spacing: 8) {
                Button {
                    session.updateMetadata { $0.color = nil }
                } label: {
                    Circle().strokeBorder(.secondary).frame(width: 22, height: 22)
                        .overlay {
                            if meta.color == nil { Image(systemName: "checkmark").font(.caption2) }
                        }
                }
                .buttonStyle(.plain).help("Default")
                ForEach(NoteAppearance.presets, id: \.hex) { preset in
                    Button {
                        session.updateMetadata { $0.color = preset.hex }
                    } label: {
                        Circle().fill(Color(nsColor: NSColor(hex: preset.hex)!)).frame(
                            width: 22, height: 22
                        )
                        .overlay {
                            if meta.color == preset.hex {
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(
                                    .black.opacity(0.7))
                            }
                        }
                    }
                    .buttonStyle(.plain).help(preset.name)
                }
            }
            HStack {
                ColorPicker(
                    "Custom",
                    selection: Binding(
                        get: { Color(nsColor: NSColor(hex: meta.color) ?? .windowBackgroundColor) },
                        set: { c in session.updateMetadata { $0.color = NSColor(c).hexString } }),
                    supportsOpacity: false)
                ColorPicker(
                    "Text",
                    selection: Binding(
                        get: { Color(nsColor: textColor) },
                        set: { c in session.updateMetadata { $0.textColor = NSColor(c).hexString } }
                    ), supportsOpacity: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Opacity \(Int(opacity * 100))%").font(.subheadline)
                Slider(
                    value: Binding(
                        get: { opacity },
                        set: { v in
                            session.updateMetadata {
                                $0.opacity = v >= 0.995 ? nil : (v * 100).rounded() / 100
                            }
                        }), in: 0.3...1)
            }
            Button("Reset Appearance") {
                session.updateMetadata {
                    $0.color = nil
                    $0.textColor = nil
                    $0.opacity = nil
                }
            }
            .disabled(meta.color == nil && meta.textColor == nil && meta.opacity == nil)
            Text("Saved in the note file, so it follows the note to your other Macs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 290)
    }

    // MARK: Reminder

    private var reminderPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reminder").font(.headline)
            Button("Later today") { setReminder(laterTodayReminder()) }
            Button("Tomorrow, 9 AM") { setReminder(tomorrowMorningReminder()) }
            Button(showReminderDatePicker ? "Hide date picker" : "Pick date") {
                showReminderDatePicker.toggle()
            }
            if showReminderDatePicker {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { meta.reminder ?? tomorrowMorningReminder() },
                        set: { setReminder($0) }), displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.graphical)
            }
            HStack {
                if meta.reminder != nil {
                    Button("Clear Reminder", role: .destructive, action: removeReminder)
                }
                Spacer()
                if model.reminderStatus?.permission == .notDetermined {
                    Button("Allow Notifications") {
                        Task {
                            await model.scheduler.requestPermission()
                            await model.reconcileReminders()
                        }
                    }
                }
            }
            Text(
                "The reminder is saved in the note, so every Mac using this folder may notify. Turn reminders off per Mac in Settings."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 300)
    }

    private func setReminder(_ date: Date) {
        let previous = meta.reminder
        session.updateMetadata { $0.reminder = date }
        showToast("Reminder set for \(reminderText(date))") {
            updateReminder(previous)
        }
        updateReminderNotifications()
        showReminder = false
    }

    private func removeReminder() {
        let previous = meta.reminder
        session.updateMetadata { $0.reminder = nil }
        showToast("Reminder removed") {
            updateReminder(previous)
        }
        updateReminderNotifications()
    }

    private func updateReminder(_ date: Date?) {
        session.updateMetadata { $0.reminder = date }
        updateReminderNotifications()
    }

    private func updateReminderNotifications() {
        Task {
            if await model.scheduler.permission() == .notDetermined {
                await model.scheduler.requestPermission()
            }
            await model.reconcileReminders()
        }
    }

    private func laterTodayReminder() -> Date {
        let calendar = Calendar.current
        let now = Date()
        if let ninePM = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now),
            ninePM > now
        {
            return ninePM
        }
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now)
            ?? now.addingTimeInterval(1800)
    }

    private func tomorrowMorningReminder() -> Date {
        let calendar = Calendar.current
        let tomorrow =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func removeLabel(_ label: String) {
        guard let index = meta.labels.firstIndex(of: label) else { return }
        session.updateMetadata { $0.labels.removeAll { $0 == label } }
        showToast("Tag removed") {
            session.updateMetadata { metadata in
                metadata.labels.insert(label, at: min(index, metadata.labels.count))
            }
        }
    }

    private func addTags(_ tags: [String]) -> Int {
        var existing = Set(meta.labels.map(\.localizedLowercase))
        let additions = tags.filter { existing.insert($0.localizedLowercase).inserted }
        guard !additions.isEmpty else { return 0 }
        session.updateMetadata { $0.labels = LabelNormalizer.normalize($0.labels + additions) }
        return additions.count
    }
}

private struct EditorToast {
    let message: String
    let undo: (() -> Void)?
}

// MARK: - Label chip

/// The remove button appears on hover so a chip can't be dropped by an accidental click.
private struct LabelChip: View {
    let text: String
    let color: NSColor
    let select: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    @FocusState private var removeFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) { Text(text).font(.caption) }
                .buttonStyle(.plain)
                .help("Filter notes by \(text)")
                .accessibilityLabel("Filter notes by tag \(text)")
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .frame(width: 12, height: 14)
            .opacity(hovering || removeFocused ? 1 : 0)
            .focused($removeFocused)
            .help("Remove label")
            .accessibilityLabel("Remove label \(text)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(nsColor: color).opacity(0.13), in: Capsule())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Remove label", remove)
    }
}

// MARK: - Window title

/// Keeps the note window's title bar in sync with the note title.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    final class TitleView: NSView {
        var title = "" { didSet { window?.title = title } }
        override func viewDidMoveToWindow() { window?.title = title }
    }

    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title }
}

// MARK: - Label picker

struct LabelPicker: View {
    let selected: [String]
    let all: [String]
    let toggle: (String) -> Void
    @State private var newLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            HStack {
                TextField("New label", text: $newLabel).onSubmit(add)
                Button("Add", action: add).disabled(
                    newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let options = Array(Set(all + selected)).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            if options.isEmpty {
                Text("Type a name above to create your first label.").font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(options, id: \.self) { label in
                            Button {
                                toggle(label)
                            } label: {
                                HStack {
                                    Image(
                                        systemName: selected.contains(label)
                                            ? "checkmark.square.fill" : "square")
                                    Text(label)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16).frame(width: 260)
    }

    private func add() {
        let l = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        if !selected.contains(l) { toggle(l) }
        newLabel = ""
    }
}

// MARK: - Version history

struct HistoryView: View {
    let model: AppModel
    let session: NoteEditSession
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [BackupStore.Version] = []
    @State private var selected: BackupStore.Version?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History").font(.title2.bold())
            Text(
                "Earlier versions saved on this Mac, including text from before sync or other apps changed the file."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                List(
                    versions,
                    selection: Binding(
                        get: { selected?.id },
                        set: { id in
                            selected = versions.first { $0.id == id }
                            load()
                        })
                ) { v in
                    VStack(alignment: .leading) {
                        Text(v.date.formatted(date: .abbreviated, time: .standard))
                        Text(label(v.reason)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(v.id)
                }
                .frame(width: 210)
                ScrollView {
                    Text(text.isEmpty ? "Select a version to preview it." : text)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Restore This Text") {
                    if let v = selected, let data = try? model.store?.backups.data(for: v),
                        let s = String(data: data, encoding: .utf8)
                    {
                        let doc = NoteDocument(text: s, filenameID: session.noteID)
                        session.setBody(doc.body)
                        dismiss()
                    }
                }
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640)
        .onAppear { versions = model.store?.backups.versions(for: session.noteID) ?? [] }
    }

    private func load() {
        guard let v = selected, let data = try? model.store?.backups.data(for: v) else {
            text = ""
            return
        }
        text =
            NoteDocument(text: String(decoding: data, as: UTF8.self), filenameID: session.noteID)
            .body
    }

    private func label(_ r: BackupStore.Reason) -> String {
        switch r {
        case .edit: "Before an edit"
        case .external: "Changed outside the app"
        case .delete: "Before deletion"
        case .conflict: "Conflicting version"
        case .recovery: "Recovered draft"
        }
    }
}
