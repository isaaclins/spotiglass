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
    /// The pins read row by row: a row this build can't read is skipped and described, its
    /// siblings stay. Throws when the file can't be read as a list at all.
    func loadPinnedItemsRowByRow(userID: String) throws -> PinnedItemsLoad
    /// Copies the account's pins file as it is now next to it, before anything is saved over
    /// it (#597). `nil` when there is no file to keep.
    func preservePinnedItemsFile(userID: String) throws -> URL?
}

/// Pins read from storage, with the rows that could not be read.
struct PinnedItemsLoad {
    var items: [PinnedItem]
    /// One line per skipped row: where it is and what was wrong.
    var unreadableRows: [String] = []
    /// Where the pins live, for the log.
    var fileURL: URL?
}

extension PinnedItemsCache {
    func loadPinnedItemsRowByRow(userID: String) throws -> PinnedItemsLoad {
        PinnedItemsLoad(items: try loadPinnedItems(userID: userID))
    }

    func preservePinnedItemsFile(userID: String) throws -> URL? { nil }
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

extension SpotifyLocalCache: PinnedItemsCache {}
