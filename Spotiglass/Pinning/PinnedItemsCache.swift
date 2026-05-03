import Foundation

/// Persistence interface for the pinned items list. Owned by ``PinnedItemsStore``;
/// implemented by ``SpotifyLocalCache`` (and a no-op fallback when the cache
/// directory is unavailable).
///
/// Keyed by Spotify user ID so signing in/out across accounts cleanly swaps the
/// pinned list without deleting per-account state on disk.
protocol PinnedItemsCache {
    func loadPinnedItems(userID: String) throws -> [PinnedItem]
    func savePinnedItems(_ items: [PinnedItem], userID: String) throws
}

/// Drop-in cache used when the on-disk cache cannot be created (e.g. the cache
/// directory is not writable). Keeps pins in memory for the session.
final class InMemoryPinnedItemsCache: PinnedItemsCache {
    private var byUserID: [String: [PinnedItem]] = [:]
    private let lock = NSLock()

    init() {}

    func loadPinnedItems(userID: String) throws -> [PinnedItem] {
        lock.lock()
        defer { lock.unlock() }
        return byUserID[userID] ?? []
    }

    func savePinnedItems(_ items: [PinnedItem], userID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        byUserID[userID] = items
    }
}
