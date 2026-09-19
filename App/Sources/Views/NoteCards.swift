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
    @State private var hovering = false

    private var note: NoteSummary { hit.note }

    var body: some View {
        let bg = NSColor(hex: note.color)
        let fg = Color(NoteAppearance.text(textHex: note.textColor, backgroundHex: note.color))
        let alpha = note.opacity ?? 1

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                ForEach(note.labels.prefix(3), id: \.self) { l in
                    Text(l).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(fg.opacity(0.12), in: Capsule())
                }
                if note.labels.count > 3 { Text("+\(note.labels.count - 3)").font(.caption2).opacity(0.6) }
                Spacer(minLength: 0)
                if let r = note.reminder {
                    Label(r.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
                        .font(.caption2)
                        .foregroundStyle(r < Date() ? .red : fg.opacity(0.7))
                } else if !tiled {
                    Text(note.updated.formatted(.relative(presentation: .named))).font(.caption2).opacity(0.55)
                }
            }
        }
        .foregroundStyle(bg == nil ? Color.primary : fg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(bg.map { Color(nsColor: $0).opacity(alpha) } ?? Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 5 : 2, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
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
