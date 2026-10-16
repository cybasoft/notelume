import NoteLumeCore
import SwiftUI

/// Stacked (compact cards) or tiled (grid) presentation of notes.
struct NoteCollectionView: View {
    let model: AppModel
    let hits: [SearchHit]

    var body: some View {
        let settings = model.settings
        ScrollView {
            if settings?.layout == .tiled {
                let size = settings?.tileSize ?? 200
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.6), spacing: 12)], spacing: 12) {
                    ForEach(hits) { hit in
                        NoteCard(model: model, hit: hit, tiled: true, showPreview: settings?.showPreviews ?? true)
                            .frame(height: size * 0.9)
                    }
                }
                .padding(14)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(hits) { hit in
                        NoteCard(model: model, hit: hit, tiled: false, showPreview: settings?.showPreviews ?? true)
                    }
                }
                .padding(14)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let settings, settings.layout == .tiled {
                HStack {
                    Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { settings.tileSize }, set: { settings.tileSize = $0 }), in: 140...340).frame(width: 140)
                    Toggle("Previews", isOn: Binding(get: { settings.showPreviews }, set: { settings.showPreviews = $0 })).toggleStyle(.checkbox)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

struct NoteCard: View {
    let model: AppModel
    let hit: SearchHit
    let tiled: Bool
    let showPreview: Bool
    var inSidebar = false
    @State private var hovering = false

    private var note: NoteSummary { hit.note }

    var body: some View {
        let bg = NSColor(hex: note.color)
        let fg = inSidebar ? Color.primary : Color(NoteAppearance.text(textHex: note.textColor, backgroundHex: note.color))
        let alpha = note.opacity ?? 1

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if inSidebar, let bg {
                    Circle().fill(Color(nsColor: bg)).frame(width: 7, height: 7)
                        .accessibilityLabel("Note color")
                }
                if note.sticky { Image(systemName: "pin.fill").font(.caption).foregroundStyle(fg.opacity(0.7)) }
                Text(note.title).font(.headline).lineLimit(tiled ? 2 : 1)
                Spacer(minLength: 4)
                if !note.isDownloaded { Image(systemName: "icloud.and.arrow.down").help("Downloading from cloud storage…") }
                if !note.issues.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(note.issues.map(\.message).joined(separator: "\n")) }
            }
            if let snippet = hit.snippet, !snippet.isEmpty {
                Text(Self.highlighted(snippet)).font(.callout).lineLimit(tiled ? 4 : 2).opacity(0.85)
            } else if showPreview, !note.preview.isEmpty {
                Text(note.preview).font(.callout).lineLimit(tiled ? 5 : 2).opacity(0.75)
            }
            if tiled { Spacer(minLength: 0) }
            HStack(spacing: 6) {
                NoteCardLabels(labels: note.labels, foreground: fg)
                Spacer(minLength: 0)
                if let r = note.reminder {
                    if tiled {
                        Image(systemName: "bell")
                            .font(.caption2)
                            .foregroundStyle(r < Date() ? .red : fg.opacity(0.7))
                            .help(r.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityLabel("Reminder: \(r.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Label(r.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
                            .font(.caption2)
                            .foregroundStyle(r < Date() ? .red : fg.opacity(0.7))
                    }
                } else if !tiled {
                    Text(note.updated.formatted(.relative(presentation: .named))).font(.caption2).opacity(0.55)
                }
            }
        }
        .foregroundStyle(fg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !inSidebar {
                RoundedRectangle(cornerRadius: 10)
                    .fill(bg.map { Color(nsColor: $0).opacity(alpha) } ?? Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 5 : 2, y: 1)
            }
        }
        .overlay {
            if !inSidebar {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture { model.openNote(note.id) }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { model.openNote(note.id) }
        Button(note.sticky ? "Unpin from Sticky" : "Make Sticky") { model.setSticky(note.id, !note.sticky) }
        Menu("Labels") {
            ForEach(model.labelCounts) { lc in
                Button { model.toggleLabel(lc.label, on: note.id) } label: {
                    if note.labels.contains(lc.label) { Label(lc.label, systemImage: "checkmark") } else { Text(lc.label) }
                }
            }
        }
        Button("Show in Finder") {
            if let dir = model.folderURL {
                NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(NoteFileName.filename(for: note.id))])
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(note.id) }
    }

    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var highlighting = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer)
            if highlighting { part.font = .callout.bold(); part.backgroundColor = .yellow.opacity(0.35) }
            result += part
            buffer = ""
        }
        for ch in snippet {
            if String(ch) == SearchHit.highlightStart { flush(); highlighting = true }
            else if String(ch) == SearchHit.highlightEnd { flush(); highlighting = false }
            else { buffer.append(ch) }
        }
        flush()
        return result
    }
}

struct NoteCardLabels: View {
    let labels: [String]
    let foreground: Color

    var body: some View {
        if let first = labels.first {
            ViewThatFits(in: .horizontal) {
                ForEach((1...min(3, labels.count)).reversed(), id: \.self) { count in
                    HStack(spacing: 4) {
                        ForEach(labels.prefix(count), id: \.self) { label in
                            tag(label)
                        }
                        overflow(after: count)
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                HStack(spacing: 4) {
                    tag(first).layoutPriority(1)
                    overflow(after: 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Labels: \(labels.joined(separator: ", "))")
        }
    }

    private func tag(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(foreground.opacity(0.85))
            .background(foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            .help(label)
    }

    @ViewBuilder private func overflow(after count: Int) -> some View {
        if labels.count > count {
            Text("+\(labels.count - count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(foreground.opacity(0.6))
                .fixedSize()
                .help(labels.dropFirst(count).joined(separator: ", "))
        }
    }
}
