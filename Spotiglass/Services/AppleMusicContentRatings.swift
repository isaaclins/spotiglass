import Foundation
import MusicKit

/// Whether an Apple Music song is explicit: the one answer every label, filter and comparison
/// uses (#518).
///
/// MusicKit on macOS gives songs saved to the library no content rating, so read as they come
/// every saved explicit song would be clean: no Explicit label, and past the clean-only filter.
/// A saved song names its catalog release (`playParams.catalogId`), and that release's rating is
/// the real one. ``resolve(_:lookup:)`` looks those ratings up before songs are shown or queued;
/// ``isExplicit(_:)`` then answers from them. A song with a rating of its own keeps it, and one
/// without a catalog ID (uploaded or matched without one) stays as MusicKit gives it.
///
/// Bounded: past ``capacity`` the least recently used entries go first. Memory only. A failed
/// lookup isn't kept, so the next read asks again.
final class AppleMusicContentRatings: @unchecked Sendable {
    static let shared = AppleMusicContentRatings()

    /// The catalog's ratings for these catalog song IDs, `true` for explicit.
    typealias CatalogLookup = @Sendable (_ catalogIDs: [String]) async throws -> [String: Bool]

    /// Lookups running at once, so a large library's first read doesn't wait on each in turn.
    static let parallelLookups = 4

    let capacity: Int
    private let lock = NSLock()
    /// The catalog ID each unrated song names, "" for none: worked out once per song, as
    /// encoding a song to read it costs time on a long list (#442).
    private var catalogIDsBySongID: LRUDictionary<String, String>
    private var explicitByCatalogID: LRUDictionary<String, Bool>

    init(capacity: Int = 20_000) {
        self.capacity = max(2, capacity)
        catalogIDsBySongID = LRUDictionary(capacity: self.capacity)
        explicitByCatalogID = LRUDictionary(capacity: self.capacity)
    }

    func isExplicit(_ song: Song) -> Bool {
        if let rating = song.contentRating { return rating == .explicit }
        guard let catalogID = catalogID(of: song) else { return false }
        return lock.withLock { explicitByCatalogID.value(forKey: catalogID) } ?? false
    }

    /// Looks up the catalog rating of each unrated song in `songs` that isn't known yet.
    func resolve(_ songs: some Sequence<Song>, lookup: @escaping CatalogLookup) async {
        var seen: Set<String> = []
        var missing: [String] = []
        for song in songs where song.contentRating == nil {
            guard let catalogID = catalogID(of: song), seen.insert(catalogID).inserted else { continue }
            if lock.withLock({ explicitByCatalogID.value(forKey: catalogID) }) == nil { missing.append(catalogID) }
        }
        guard !missing.isEmpty else { return }
        // As many IDs per lookup as MusicKit's ID filter takes elsewhere.
        let batches = MusicKitLibraryLookup.batches(missing)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { await self.store(batch, lookup: lookup) }
            }
            for _ in 0..<Self.parallelLookups { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private func store(_ batch: [String], lookup: CatalogLookup) async {
        guard let ratings = try? await lookup(batch) else { return }
        lock.withLock {
            // An ID the catalog doesn't list (gone from this storefront) reads as clean, as
            // before, and isn't asked about again.
            for id in batch { explicitByCatalogID.setValue(ratings[id] ?? false, forKey: id) }
        }
    }

    /// The catalog release a saved song names; `nil` for a catalog song and for a song without one.
    private func catalogID(of song: Song) -> String? {
        let songID = song.id.rawValue
        // Catalog songs carry their own rating (or have none to give).
        guard !MusicKitLibraryLookup.isCatalogID(songID) else { return nil }
        if let known = lock.withLock({ catalogIDsBySongID.value(forKey: songID) }) {
            return known.isEmpty ? nil : known
        }
        let found = Self.catalogID(fromPlayParameters: song.playParameters)
            ?? AppleMusicSongIdentity(encoding: song).catalogID
        let catalogID = found.flatMap { $0 != songID && MusicKitLibraryLookup.isCatalogID($0) ? $0 : nil }
        lock.withLock { catalogIDsBySongID.setValue(catalogID ?? "", forKey: songID) }
        return catalogID
    }

    /// `catalogId` from the play parameters alone: much cheaper than encoding the whole song,
    /// which is only needed when they don't carry it.
    private static func catalogID(fromPlayParameters parameters: PlayParameters?) -> String? {
        guard let parameters,
              let data = try? JSONEncoder().encode(parameters),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch object["catalogId"] {
        case let id as String: return id.isEmpty ? nil : id
        case let id as NSNumber: return id.stringValue
        default: return nil
        }
    }
}
