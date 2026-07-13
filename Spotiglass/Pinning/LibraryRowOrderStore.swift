import Foundation

/// Persists the visible Library-section row order (the Home token plus
/// pinned-item tokens) per Spotify user so a user-arranged order, including
/// Home's slot between pins, survives relaunch.
///
/// The pinned items themselves are persisted by ``PinnedItemsStore``; this
/// store only remembers where the rows sit. Stale tokens (pins removed while
/// the order was on disk) are filtered out by
/// ``LibrarySidebarOrder/normalizedOrder(existing:pinnedItemIDs:)`` on load,
/// so a saved order can never resurrect or invent pins.
enum LibraryRowOrderStore {
    private static let keyPrefix = "library.rowOrder."

    static func key(forUserID userID: String) -> String {
        keyPrefix + userID
    }

    static func load(userID: String, defaults: UserDefaults = .standard) -> [String]? {
        defaults.stringArray(forKey: key(forUserID: userID))
    }

    static func save(_ order: [String], userID: String, defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: key(forUserID: userID))
    }
}
