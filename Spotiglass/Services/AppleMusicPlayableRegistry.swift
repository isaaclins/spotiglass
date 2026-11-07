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
/// Bounded: past ``capacity`` the least recently used songs go first. Registering a song again
/// (its list was mapped again) or looking it up counts as a use, so the list on screen keeps
/// its songs (#400). A URI that is no longer here falls back to a library or catalog lookup in
/// the player.
final class AppleMusicPlayableRegistry: @unchecked Sendable {
    static let shared = AppleMusicPlayableRegistry()

    let capacity: Int
    private let lock = NSLock()
    private var songs: LRUDictionary<String, Song>

    init(capacity: Int = 20_000) {
        self.capacity = max(2, capacity)
        songs = LRUDictionary(capacity: self.capacity)
    }

    func register(_ song: Song, for uri: String) {
        lock.withLock { songs.setValue(song, forKey: uri) }
    }

    func song(for uri: String) -> Song? {
        lock.withLock { songs.value(forKey: uri) }
    }
}
