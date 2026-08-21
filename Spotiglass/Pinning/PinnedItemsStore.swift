import Combine
import Foundation

/// Source of truth for the pinned-items sidebar list.
///
/// Persists per Spotify user ID so a single Mac running multiple accounts (or
/// signing in / out across accounts) keeps each account's pins isolated.
@MainActor
final class PinnedItemsStore: ObservableObject {
    @Published private(set) var items: [PinnedItem] = []
    /// True when the account lookup that the pinned list depends on failed, so
    /// an empty list means "could not load" rather than "no pins". The sidebar
    /// uses this to offer a retry instead of rendering as if the user had never
    /// pinned anything (#133).
    @Published private(set) var didFailToBind = false

    private let cache: PinnedItemsCache?
    private(set) var boundUserID: String?
    /// Invalidates profile lookups that started before a sign-out or reconnect.
    private(set) var bindingGeneration = 0

    init(cache: PinnedItemsCache?) {
        self.cache = cache
    }

    /// Bind the store to a Spotify user ID. Loads that account's pinned list
    /// from disk; passing `nil` clears the in-memory list (used at sign-out).
    /// An optional generation rejects a result from an older account lookup.
    func bind(userID: String?, bindingGeneration: Int? = nil) {
        if let bindingGeneration, bindingGeneration != self.bindingGeneration {
            return
        }
        boundUserID = userID
        didFailToBind = false
        guard let userID, let cache else {
            items = []
            return
        }
        if let loaded = try? cache.loadPinnedItems(userID: userID) {
            let migrated = PinnedItem.migrateLegacyTrackPins(loaded)
            items = migrated
            if migrated != loaded {
                persist()
            }
        } else {
            items = []
            SpotiglassLog.error(SpotiglassLog.pinning, "Failed to load pinned items for user")
        }
    }

    /// Records that the account could not be resolved, after the caller has
    /// exhausted its retries.
    func reportBindingFailure() {
        guard boundUserID == nil else { return }
        didFailToBind = true
    }

    /// Returns `true` if the item was newly pinned, `false` if it was already
    /// pinned. Optional ``index`` inserts at a specific position; clamping is
    /// applied so callers don't have to bounds-check.
    @discardableResult
    func pin(_ item: PinnedItem, at index: Int? = nil) -> Bool {
        let normalizedItem = item.migratedLegacyTrackPin()
        guard !isPinned(id: normalizedItem.id) else { return false }
        let clamped: Int
        if let index {
            clamped = max(0, min(index, items.count))
        } else {
            clamped = items.count
        }
        items.insert(normalizedItem, at: clamped)
        persist()
        return true
    }

    func unpin(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
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

    /// Reorders the pinned list to match ``orderedIDs`` (the visible Library
    /// row order). Items missing from ``orderedIDs`` keep their relative order
    /// at the end; unknown IDs are ignored, so a stale order can never drop
    /// or invent pins.
    func applyOrder(_ orderedIDs: [String]) {
        var next: [PinnedItem] = []
        for id in orderedIDs {
            if let item = items.first(where: { $0.id == id }) {
                next.append(item)
            }
        }
        next.append(contentsOf: items.filter { item in !orderedIDs.contains(item.id) })
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
        if isPinned(id: pinID) { return true }
        guard kind == .track else { return false }
        return items.contains {
            $0.kind == .track
                && PinnedItem.canonicalTrackID(fromSpotifyURI: $0.spotifyURI) == spotifyID
        }
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
        bindingGeneration &+= 1
        items = []
        boundUserID = nil
    }

    private func persist() {
        guard let userID = boundUserID, let cache else { return }
        do {
            try cache.savePinnedItems(items, userID: userID)
        } catch {
            SpotiglassLog.error(SpotiglassLog.pinning, "Failed to save pinned items: \(error.localizedDescription)")
        }
    }
}
