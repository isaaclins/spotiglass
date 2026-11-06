import Foundation
import MusicKit

/// Library artwork from MusicKit comes as `musicKit://artwork/...` URLs, which no URL loader
/// can fetch; only MusicKit's `ArtworkImage` view can draw them. The neutral models carry URLs,
/// so the Apple Music mapping registers each such artwork here under its URL, and the artwork
/// views draw it with `ArtworkImage` instead of downloading it. Catalog artwork stays plain
/// https and goes through the normal image cache.
final class AppleMusicArtworkRegistry: @unchecked Sendable {
    static let shared = AppleMusicArtworkRegistry()

    /// Enough for a large library; past it the registry starts over and items register again
    /// the next time they are mapped.
    static let maxEntries = 20_000

    private let lock = NSLock()
    private var artworkByURL: [String: Artwork] = [:]
    /// The same artwork under the item's pin ID (`playlist:<id>`, ...). Library artwork URLs
    /// change between launches, so a pin saved with last session's URL finds its cover here
    /// once the item has been mapped again in this session.
    private var artworkByItemKey: [String: Artwork] = [:]

    /// URLs a URL loader can't fetch and only this registry can resolve.
    static func needsMusicKit(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "https" && scheme != "http"
    }

    func register(_ artwork: Artwork, for url: URL, itemKey: String? = nil) {
        lock.withLock {
            if artworkByURL.count >= Self.maxEntries {
                artworkByURL.removeAll(keepingCapacity: true)
            }
            artworkByURL[url.absoluteString] = artwork
            guard let itemKey else { return }
            if artworkByItemKey.count >= Self.maxEntries {
                artworkByItemKey.removeAll(keepingCapacity: true)
            }
            artworkByItemKey[itemKey] = artwork
        }
    }

    /// The artwork for `url`, or else the artwork last registered for `itemKey`.
    func artwork(for url: URL, itemKey: String? = nil) -> Artwork? {
        lock.withLock {
            artworkByURL[url.absoluteString] ?? itemKey.flatMap { artworkByItemKey[$0] }
        }
    }
}
