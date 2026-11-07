import Foundation
import MusicKit

/// Library artwork from MusicKit comes as `musicKit://artwork/...` URLs, which no URL loader
/// can fetch; only MusicKit's `ArtworkImage` view can draw them. The neutral models carry URLs,
/// so the Apple Music mapping registers each such artwork here under its URL, and the artwork
/// views draw it with `ArtworkImage` instead of downloading it. Catalog artwork stays plain
/// https and goes through the normal image cache.
final class AppleMusicArtworkRegistry: @unchecked Sendable {
    static let shared = AppleMusicArtworkRegistry()

    /// Enough for a large library. Past it the least recently used artworks go first, so the
    /// covers on screen and on pins (which are read on every draw) keep drawing; an evicted
    /// item registers again the next time it is mapped (#400).
    static let maxEntries = 20_000

    private let lock = NSLock()
    private var artworkByURL: LRUDictionary<String, Artwork>
    /// The same artwork under the item's pin ID (`playlist:<id>`, ...). Library artwork URLs
    /// change between launches, so a pin saved with last session's URL finds its cover here
    /// once the item has been mapped again in this session.
    private var artworkByItemKey: LRUDictionary<String, Artwork>

    init(capacity: Int = AppleMusicArtworkRegistry.maxEntries) {
        artworkByURL = LRUDictionary(capacity: capacity)
        artworkByItemKey = LRUDictionary(capacity: capacity)
    }

    /// URLs a URL loader can't fetch and only this registry can resolve.
    static func needsMusicKit(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "https" && scheme != "http"
    }

    func register(_ artwork: Artwork, for url: URL, itemKey: String? = nil) {
        lock.withLock {
            artworkByURL.setValue(artwork, forKey: url.absoluteString)
            guard let itemKey else { return }
            artworkByItemKey.setValue(artwork, forKey: itemKey)
        }
    }

    /// The artwork for `url`, or else the artwork last registered for `itemKey`. A hit counts
    /// as a use, which keeps drawn covers from being evicted.
    func artwork(for url: URL, itemKey: String? = nil) -> Artwork? {
        lock.withLock {
            artworkByURL.value(forKey: url.absoluteString)
                ?? itemKey.flatMap { artworkByItemKey.value(forKey: $0) }
        }
    }
}
