import Foundation
import Observation
import NoteLumeCore

enum EditorMode: String, CaseIterable, Identifiable {
    case visual, source
    var id: String { rawValue }
    var title: String { self == .visual ? "Visual (live Markdown)" : "Source (raw Markdown)" }
}

enum CollectionLayout: String, CaseIterable, Identifiable {
    case stacked, tiled
    var id: String { rawValue }
    var title: String { self == .stacked ? "Stacked" : "Tiled" }
}

enum StickyPlacement: String, CaseIterable, Identifiable {
    case remember, cascade, nearCursor, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remember: "Where it was last time"
        case .cascade: "Cascade from the previous note"
        case .nearCursor: "Near the mouse pointer"
        case .topRight: "Top-right corner of the screen"
        }
    }
}

enum RecentNoteSort: String, CaseIterable, Identifiable {
    case updated, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updated: "Recently updated"
        case .created: "Recently created"
        case .title: "Title (A-Z)"
        }
    }

    var searchSort: SearchSort {
        switch self {
        case .updated: .updated
        case .created: .created
        case .title: .title
        }
    }
}

struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon modifier mask
    var display: String        // e.g. "⌃⌥N"
}

/// Preferences that belong to *this Mac*, stored in the local SQLite database
/// (requirements §3, §6, §8). Nothing here is written to the notes folder or synced.
@MainActor
@Observable
final class DeviceSettings {
    @ObservationIgnored private let index: NoteIndex

    var editorMode: EditorMode { didSet { save("editorMode", editorMode.rawValue) } }
    var layout: CollectionLayout { didSet { save("layout", layout.rawValue) } }
    var tileSize: Double { didSet { save("tileSize", String(tileSize)) } }
    var showPreviews: Bool { didSet { save("showPreviews", showPreviews ? "1" : "0") } }
    var stickyAlwaysOnTop: Bool { didSet { save("stickyAlwaysOnTop", stickyAlwaysOnTop ? "1" : "0") } }
    var fadeWhenUnfocused: Bool { didSet { save("fadeWhenUnfocused", fadeWhenUnfocused ? "1" : "0") } }
    var menuBarRecentCount: Int { didSet { save("menuBarRecentCount", String(min(20, max(5, menuBarRecentCount)))) } }
    var menuBarRecentSort: RecentNoteSort { didSet { save("menuBarRecentSort", menuBarRecentSort.rawValue) } }
    var stickyPlacement: StickyPlacement { didSet { save("stickyPlacement", stickyPlacement.rawValue) } }
    var showInDock: Bool { didSet { save("showInDock", showInDock ? "1" : "0") } }
    var spotlightEnabled: Bool { didSet { save("spotlightEnabled", spotlightEnabled ? "1" : "0") } }
    var newNoteHotKey: HotKeySpec? { didSet { saveJSON("hotkey.newNote", newNoteHotKey) } }
    var searchHotKey: HotKeySpec? { didSet { saveJSON("hotkey.search", searchHotKey) } }

    init(index: NoteIndex) {
        self.index = index
        func get(_ k: String) -> String? { (try? index.setting(k)) ?? nil }
        editorMode = EditorMode(rawValue: get("editorMode") ?? "") ?? .visual
        layout = CollectionLayout(rawValue: get("layout") ?? "") ?? .stacked
        tileSize = Double(get("tileSize") ?? "") ?? 200
        showPreviews = (get("showPreviews") ?? "1") == "1"
        stickyAlwaysOnTop = (get("stickyAlwaysOnTop") ?? "1") == "1"
        fadeWhenUnfocused = (get("fadeWhenUnfocused") ?? "0") == "1"
        menuBarRecentCount = min(20, max(5, Int(get("menuBarRecentCount") ?? "6") ?? 6))
        menuBarRecentSort = RecentNoteSort(rawValue: get("menuBarRecentSort") ?? "") ?? .updated
        stickyPlacement = StickyPlacement(rawValue: get("stickyPlacement") ?? "") ?? .remember
        showInDock = (get("showInDock") ?? "1") == "1"
        spotlightEnabled = (get("spotlightEnabled") ?? "1") == "1"
        newNoteHotKey = Self.decode(get("hotkey.newNote")) ?? HotKeySpec(keyCode: 45, modifiers: Self.controlOption, display: "⌃⌥N")
        searchHotKey = Self.decode(get("hotkey.search")) ?? HotKeySpec(keyCode: 3, modifiers: Self.controlOption, display: "⌃⌥F")
    }

    static let controlOption: UInt32 = 0x1000 | 0x0800   // controlKey | optionKey

    private func save(_ key: String, _ value: String) { try? index.setSetting(key, value) }

    private func saveJSON(_ key: String, _ spec: HotKeySpec?) {
        if let spec, let data = try? JSONEncoder().encode(spec), let s = String(data: data, encoding: .utf8) {
            try? index.setSetting(key, s)
        } else {
            try? index.setSetting(key, "none")
        }
    }

    private static func decode(_ s: String?) -> HotKeySpec? {
        guard let s, s != "none", let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HotKeySpec.self, from: d)
    }
}
