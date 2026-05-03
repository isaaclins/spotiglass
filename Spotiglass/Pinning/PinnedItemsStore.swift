import Combine
import Foundation

/// Source of truth for the pinned-items sidebar list.
///
/// Persists per Spotify user ID so a single Mac running multiple accounts (or
/// signing in / out across accounts) keeps each account's pins isolated.
@MainActor
final class PinnedItemsStore: ObservableObject {
    @Published private(set) var items: [PinnedItem] = []

    private let cache: PinnedItemsCache?
    private(set) var boundUserID: String?

    init(cache: PinnedItemsCache?) {
        self.cache = cache
    }

    /// Bind the store to a Spotify user ID. Loads that account's pinned list
    /// from disk; passing `nil` clears the in-memory list (used at sign-out).
    func bind(userID: String?) {
        boundUserID = userID
        guard let userID, let cache else {
            items = []
            return
        }
        items = (try? cache.loadPinnedItems(userID: userID)) ?? []
    }

    /// Returns `true` if the item was newly pinned, `false` if it was already
    /// pinned. Optional ``index`` inserts at a specific position; clamping is
    /// applied so callers don't have to bounds-check.
    @discardableResult
    func pin(_ item: PinnedItem, at index: Int? = nil) -> Bool {
        guard !isPinned(id: item.id) else { return false }
        let clamped: Int
        if let index {
            clamped = max(0, min(index, items.count))
        } else {
            clamped = items.count
        }
        items.insert(item, at: clamped)
        persist()
        return true
    }

    func unpin(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Reorder within the pinned list. The destination index follows the
    /// SwiftUI `move(fromOffsets:toOffset:)` convention: it is the position
    /// **before** removal, so dropping after element 2 uses `to: 3`.
    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let item = items.remove(at: source)
        let adjustedDest = destination > source ? destination - 1 : destination
        let clamped = max(0, min(adjustedDest, items.count))
        items.insert(item, at: clamped)
        persist()
    }

    /// Direct-index move used by drop targets that compute insertion indices
    /// against the current (post-removal) array layout. Avoids the +/-1
    /// bookkeeping callers would otherwise have to do themselves.
    func reorder(itemID: String, toInsertionIndex insertionIndex: Int) {
        guard let source = items.firstIndex(where: { $0.id == itemID }) else { return }
        let withoutSource = items.enumerated().filter { $0.offset != source }.map(\.element)
        let clamped = max(0, min(insertionIndex, withoutSource.count))
        var next = withoutSource
        next.insert(items[source], at: clamped)
        guard next != items else { return }
        items = next
        persist()
    }

    func isPinned(id: String) -> Bool {
        items.contains { $0.id == id }
    }

    /// Convenience: stable-id lookup for source surfaces that only know their
    /// Spotify ID + kind (track row, album card, artist header, …).
    func isPinned(spotifyID: String, kind: PinnedItemKind) -> Bool {
        let pinID = PinnedItem.id(forKind: kind, spotifyID: spotifyID)
        return isPinned(id: pinID)
    }

    func markStale(id: String, _ stale: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isStale != stale else { return }
        items[idx].isStale = stale
        persist()
    }

    /// Clears the in-memory list without touching disk. Used at sign-out so
    /// that signing back into the same account restores the pins, while
    /// signing into a different account swaps to that account's list cleanly.
    func clearForSignOut() {
        items = []
        boundUserID = nil
    }

    private func persist() {
        guard let userID = boundUserID, let cache else { return }
        try? cache.savePinnedItems(items, userID: userID)
    }
}
