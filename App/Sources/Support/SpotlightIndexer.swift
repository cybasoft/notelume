import CoreSpotlight
import Foundation
import NoteLumeCore
import UniformTypeIdentifiers

/// Optional Spotlight integration (requirements §7). Spotlight is a convenience
/// only: in-app search never depends on it. Only titles, labels and a short
/// preview are shared, never full note bodies.
@MainActor
final class SpotlightIndexer {
    private let domain = "com.cybasoft.notelume.notes"
    private var index: CSSearchableIndex { .default() }

    func reindexAll(from noteIndex: NoteIndex, enabled: Bool) {
        guard enabled else { clear(); return }
        let hits = (try? noteIndex.search(SearchQuery(limit: 100_000))) ?? []
        index.indexSearchableItems(hits.map { item(for: $0.note) }) { _ in }
    }

    func update(updated: Set<UUID>, removed: Set<UUID>, index noteIndex: NoteIndex) {
        let items = updated.compactMap { try? noteIndex.summary(id: $0) }.map(item(for:))
        if !items.isEmpty { index.indexSearchableItems(items) { _ in } }
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: removed.map { $0.uuidString.lowercased() }) { _ in } }
    }

    func clear() {
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    private func item(for note: NoteSummary) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = note.title
        attrs.contentDescription = note.preview
        attrs.keywords = note.labels
        attrs.contentModificationDate = note.updated
        attrs.contentCreationDate = note.created
        return CSSearchableItem(uniqueIdentifier: note.id.uuidString.lowercased(), domainIdentifier: domain, attributeSet: attrs)
    }

    /// Note ID from a Spotlight activation, if any.
    static func noteID(from activity: NSUserActivity) -> UUID? {
        guard let s = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return UUID(uuidString: s)
    }
}
