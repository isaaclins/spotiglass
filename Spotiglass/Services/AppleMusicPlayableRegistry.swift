import Foundation
import MusicKit

/// The MusicKit songs behind the `applemusic:song:` URIs the browser shows, so playback can
/// queue the exact item a row was built from.
///
/// A row's id can't always be looked up again: on macOS a library playlist's tracks carry
/// numeric ids, while a library request for those ids answers with songs whose ids are
/// `i.`-prefixed, so the answer can't be matched back to the row. Remembering the item at
/// mapping time avoids the second lookup altogether.
///
/// Bounded: past ``capacity`` the oldest half is dropped. A URI that is no longer here falls
/// back to a library or catalog lookup in the player.
final class AppleMusicPlayableRegistry: @unchecked Sendable {
    static let shared = AppleMusicPlayableRegistry()

    let capacity: Int
    private let lock = NSLock()
    private var songs: [String: Song] = [:]
    private var order: [String] = []

    init(capacity: Int = 20_000) {
        self.capacity = max(2, capacity)
    }

    func register(_ song: Song, for uri: String) {
        lock.lock()
        defer { lock.unlock() }
        if songs.updateValue(song, forKey: uri) == nil {
            order.append(uri)
        }
        guard order.count > capacity else { return }
        let dropped = order.prefix(order.count - capacity / 2)
        for key in dropped { songs.removeValue(forKey: key) }
        order.removeFirst(dropped.count)
    }

    func song(for uri: String) -> Song? {
        lock.lock()
        defer { lock.unlock() }
        return songs[uri]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return songs.count
    }
}
