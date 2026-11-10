import Foundation
import MusicKit

/// The IDs MusicKit keeps for a library song beyond the one it shows.
///
/// MusicKit's public API has no catalog ID, cloud library ID or Music persistent ID for a library
/// song, but encoding the item writes them out (`playParams.catalogId`,
/// `playParams.musicKit_persistentID`, `playParams.musicKit_libraryID`). Each one is optional.
struct AppleMusicSongIdentity: Equatable {
    var catalogID: String?
    var cloudLibraryID: String?
    /// The Music app's persistent ID as MusicKit writes it: a signed decimal.
    var musicKitPersistentID: String?

    init(catalogID: String? = nil, cloudLibraryID: String? = nil, musicKitPersistentID: String? = nil) {
        self.catalogID = catalogID
        self.cloudLibraryID = cloudLibraryID
        self.musicKitPersistentID = musicKitPersistentID
    }

    init<Item: Encodable>(encoding item: Item) {
        guard let data = try? JSONEncoder().encode(item) else {
            self.init()
            return
        }
        self.init(encoded: data)
    }

    init(encoded data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.init()
            return
        }
        let attributes = object["attributes"] as? [String: Any]
        let playParams = attributes?["playParams"] as? [String: Any]
        let identifiers = (object["meta"] as? [String: Any])?["musicKit_identifierSet"] as? [String: Any]
        let id = object["id"] as? String
        let catalog = Self.string(playParams?["catalogId"])
            ?? Self.string((identifiers?["catalogID"] as? [String: Any])?["value"])
        let cloud = Self.string(playParams?["musicKit_libraryID"])
            ?? Self.string(identifiers?["libraryID"])
            ?? (id?.hasPrefix("i.") == true ? id : nil)
        let persistent = Self.string(playParams?["musicKit_persistentID"])
            ?? Self.string((identifiers?["deviceLocalID"] as? [String: Any])?["value"])
        self.init(catalogID: catalog, cloudLibraryID: cloud, musicKitPersistentID: persistent)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// Every ID this song is known by, with the one MusicKit shows.
    func keys(itemID: String) -> Set<String> {
        Set([itemID, catalogID, cloudLibraryID].compactMap { $0 })
    }
}

/// Songs MusicKit listed in a library playlist, by the ID it showed them under.
///
/// Inside a library playlist MusicKit lists a song under the Music app's persistent ID (as a
/// signed decimal), which `MusicLibraryRequest<Song>` filtered by ID does not find. The provider
/// records each such song here when it reads the playlist, so an edit on that row knows the
/// song's other IDs. Bounded to `maxEntries`, least recently used first out (reading a playlist
/// again or editing one of its rows counts as a use); memory only.
final class AppleMusicSongReferenceRegistry: @unchecked Sendable {
    static let shared = AppleMusicSongReferenceRegistry()
    static let maxEntries = 5_000

    /// The date MusicKit says a song was added to the library; separate because MusicKit can't
    /// decode it from JSON, so tests give it.
    let addedDate: @Sendable (Song) -> Date?

    init(addedDate: @escaping @Sendable (Song) -> Date? = { $0.libraryAddedDate }) {
        self.addedDate = addedDate
    }

    private let lock = NSLock()
    private var references = LRUDictionary<String, AppleMusicSongReference>(capacity: AppleMusicSongReferenceRegistry.maxEntries)
    /// Each song's other IDs, worked out once: encoding a song to read them takes about a
    /// quarter of a millisecond, a fifth of a second for an 800-song playlist that was paid again
    /// on every open (#442). Keyed by item ID and whether the song is in the library, as adding
    /// it gives it a cloud library ID.
    private var identities = LRUDictionary<String, AppleMusicSongIdentity>(capacity: AppleMusicSongReferenceRegistry.maxIdentities)
    static let maxIdentities = 20_000

    func remember(_ reference: AppleMusicSongReference) {
        lock.withLock { references.setValue(reference, forKey: reference.itemID) }
    }

    func reference(for itemID: String) -> AppleMusicSongReference? {
        lock.withLock { references.value(forKey: itemID) }
    }

    /// Changes every remembered row of the song with these keys: a playlist row is remembered
    /// under its persistent ID, while a like from search names the song by its catalog ID.
    func update(matching keys: Set<String>, _ change: (inout AppleMusicSongReference) -> Void) {
        lock.withLock {
            references.updateValues { reference in
                if !reference.matchKeys.isDisjoint(with: keys) { change(&reference) }
            }
        }
    }

    /// Records the songs of a library playlist or album that MusicKit listed under a persistent
    /// ID. `playlistID` is the playlist they were read from: a song from Apple Music can be in a
    /// playlist without being in the library, and the Music app then finds it only there.
    func remember(_ tracks: [Track], playlistID: String? = nil) {
        let playlistPersistentID = playlistID.flatMap(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID:))
        for case let .song(song) in tracks where MusicKitLibraryLookup.isPersistentID(song.id.rawValue) {
            let isInLibrary = addedDate(song) != nil
            var reference = MusicKitLibraryLookup.reference(
                song,
                identity: identity(of: song, isInLibrary: isInLibrary),
                itemID: song.id.rawValue,
                isInLibrary: isInLibrary
            )
            reference.sourcePlaylistPersistentID = playlistPersistentID
            remember(reference)
        }
    }

    /// Works out the other IDs of the songs a library playlist lists under a persistent ID ahead
    /// of time, so opening the playlist later doesn't have to (#442).
    func prepareIdentities(of tracks: [Track]) {
        for case let .song(song) in tracks where MusicKitLibraryLookup.isPersistentID(song.id.rawValue) {
            _ = identity(of: song, isInLibrary: addedDate(song) != nil)
        }
    }

    private func identity(of song: Song, isInLibrary: Bool) -> AppleMusicSongIdentity {
        let key = "\(song.id.rawValue)|\(isInLibrary)"
        if let known = lock.withLock({ identities.value(forKey: key) }) { return known }
        let identity = AppleMusicSongIdentity(encoding: song)
        lock.withLock { identities.setValue(identity, forKey: key) }
        return identity
    }
}

/// The live library lookups behind `AppleMusicLibraryEditor`, read through `MusicLibraryRequest`.
/// A library request filtered by ID matches a song's library ID and its catalog ID alike.
struct MusicKitLibraryLookup: AppleMusicLibraryLookup {
    /// MusicKit's filter takes this many IDs at a time.
    static let batchSize = 100

    var registry: AppleMusicSongReferenceRegistry = .shared

    func songs(ids: [String]) async throws -> [AppleMusicSongReference] {
        var librarySongs: [Song] = []
        for batch in Self.batches(Array(Set(ids))) {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            librarySongs += try await request.response().items
        }
        let identified = librarySongs.map { ($0, AppleMusicSongIdentity(encoding: $0)) }
        return ids.map { id in
            guard let (song, identity) = identified.first(where: { $0.0.id.rawValue == id || $0.1.catalogID == id }) else {
                if let known = registry.reference(for: id) { return known }
                if Self.isPersistentID(id) {
                    // A playlist row: the song is in the library, under this persistent ID.
                    return AppleMusicSongReference(
                        itemID: id,
                        musicAppPersistentID: AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: id),
                        isInLibrary: true
                    )
                }
                return AppleMusicSongReference(itemID: id, catalogID: Self.isCatalogID(id) ? id : nil, isInLibrary: false)
            }
            return Self.reference(song, identity: identity, itemID: id)
        }
    }

    func catalogTracks(ids: [String]) async throws -> [MusicTrack] {
        let catalogIDs = ids.filter(Self.isCatalogID)
        guard !catalogIDs.isEmpty else { return [] }
        var tracks: [MusicTrack] = []
        for batch in Self.batches(catalogIDs) {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            request.properties = [.albums]
            tracks += try await request.response().items.map(AppleMusicItemMapping.track)
        }
        return tracks
    }

    func catalogAlbumTracks(albumIDs: [String]) async throws -> [MusicTrack] {
        let catalogIDs = albumIDs.filter(Self.isCatalogID)
        guard !catalogIDs.isEmpty else { return [] }
        var tracks: [MusicTrack] = []
        for batch in Self.batches(catalogIDs) {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            request.properties = [.tracks]
            for album in try await request.response().items {
                // Not MusicKit's next batch: on a catalog album it closes the app (#465).
                let albumTracks = try await AppleMusicCatalogPages.collect(
                    album.tracks,
                    limit: .max,
                    relationship: AppleMusicCatalogRelationship(kind: "albums", id: album.id.rawValue, name: "tracks")
                )
                tracks += albumTracks.map { AppleMusicItemMapping.track($0, album: album) }
            }
        }
        return tracks
    }

    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference] {
        var references: [AppleMusicAlbumReference] = []
        for id in ids {
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            guard let album = try await request.response().items.first else {
                references.append(AppleMusicAlbumReference(
                    itemID: id,
                    catalogID: Self.isCatalogID(id) ? id : nil,
                    isInLibrary: false,
                    librarySongs: []
                ))
                continue
            }
            let detailed = try await album.with([.tracks])
            var songs: [AppleMusicSongReference] = []
            var batch = detailed.tracks
            while let tracks = batch {
                for case let .song(song) in tracks {
                    songs.append(Self.reference(song, identity: AppleMusicSongIdentity(encoding: song), itemID: song.id.rawValue))
                }
                batch = tracks.hasNextBatch ? try await tracks.nextBatch() : nil
            }
            let albumIdentity = AppleMusicSongIdentity(encoding: album)
            references.append(AppleMusicAlbumReference(
                itemID: id,
                catalogID: albumIdentity.catalogID ?? (Self.isCatalogID(id) ? id : nil),
                isInLibrary: true,
                librarySongs: songs
            ))
        }
        return references
    }

    func playlist(id: String) async throws -> AppleMusicPlaylistReference? {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else { return nil }
        let persistent = AppleMusicSongIdentity(encoding: playlist).musicKitPersistentID ?? playlist.id.rawValue
        return AppleMusicPlaylistReference(
            name: playlist.name,
            musicAppPersistentID: AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: persistent)
        )
    }

    // MARK: - Helpers

    /// Catalog IDs are short positive numbers; library IDs are `i.…`/`l.…`/`p.…` or a
    /// persistent ID of 15 to 20 digits.
    static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 12 && id.allSatisfy(\.isASCIIDigit)
    }

    /// The Music app's persistent ID as MusicKit writes it: a signed 64-bit decimal, longer than
    /// any catalog ID.
    static func isPersistentID(_ id: String) -> Bool {
        !isCatalogID(id) && Int64(id) != nil
    }

    /// The library song with this persistent ID, as MusicKit keeps it under its cloud library ID.
    /// A song that is only in a playlist has such an entry too, and only that entry carries its
    /// catalog ID (#401); its title finds it, its persistent ID tells it from namesakes.
    func libraryIdentity(of reference: AppleMusicSongReference) async throws -> AppleMusicSongIdentity? {
        guard let title = reference.title, !title.isEmpty, let persistentID = reference.musicKitPersistentID else { return nil }
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.title, equalTo: title)
        return try await request.response().items
            .lazy
            .map { AppleMusicSongIdentity(encoding: $0) }
            .first { $0.musicKitPersistentID == persistentID }
    }

    /// `isInLibrary`: MusicKit lists a playlist's songs like library songs, and finds a
    /// playlist-only song by its ID too; only a song in the library has the date it was added
    /// (checked against the Music app on 22 playlist rows, #401).
    static func reference(
        _ song: Song,
        identity: AppleMusicSongIdentity,
        itemID: String,
        isInLibrary: Bool? = nil
    ) -> AppleMusicSongReference {
        let persistent = identity.musicKitPersistentID ?? (isCatalogID(song.id.rawValue) ? nil : song.id.rawValue)
        var reference = AppleMusicSongReference(
            itemID: itemID,
            catalogID: identity.catalogID,
            cloudLibraryID: identity.cloudLibraryID,
            musicAppPersistentID: persistent.flatMap(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID:)),
            isInLibrary: isInLibrary ?? (song.libraryAddedDate != nil),
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle
        )
        // Every route that finds the song keeps the row, so an add shows before the library lists it.
        reference.shownTrack = AppleMusicItemMapping.track(song)
        return reference
    }

    static func batches(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
