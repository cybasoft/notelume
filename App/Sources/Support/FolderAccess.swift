import AppKit

/// Remembers the user's notes folder across launches using a security-scoped
/// bookmark, which works for local folders, iCloud Drive, Dropbox and any other
/// filesystem-backed location the user picks (requirements §1).
@MainActor
final class FolderAccess {
    private let key = "notesFolderBookmark"
    private(set) var url: URL?

    /// Resolves the saved bookmark and starts access. Returns nil if none is saved or it went stale.
    func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        guard resolved.startAccessingSecurityScopedResource() else { return nil }
        if stale { remember(resolved) }
        stop()
        url = resolved
        return resolved
    }

    /// Lets the user pick a folder. The panel grants sandbox access to the choice.
    func choose(startingAt current: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Notes Folder"
        panel.message = "NoteLume stores each note as a Markdown file in this folder. Pick a local folder, or one inside iCloud Drive, Dropbox or another synced location."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = current
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        guard picked.startAccessingSecurityScopedResource() else { return nil }
        remember(picked)
        stop()
        url = picked
        return picked
    }

    private func remember(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func stop() { url?.stopAccessingSecurityScopedResource(); url = nil }
}
