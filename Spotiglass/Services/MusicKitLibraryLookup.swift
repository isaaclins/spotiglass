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

/// The live library lookups behind `AppleMusicLibraryEditor`, read through `MusicLibraryRequest`.
/// A library request filtered by ID matches a song's library ID and its catalog ID alike.
struct MusicKitLibraryLookup: AppleMusicLibraryLookup {
    /// MusicKit's filter takes this many IDs at a time.
    static let batchSize = 100

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
            itemID: id,
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

    static func reference(_ song: Song, identity: AppleMusicSongIdentity, itemID: String) -> AppleMusicSongReference {
        let persistent = identity.musicKitPersistentID ?? (isCatalogID(song.id.rawValue) ? nil : song.id.rawValue)
        return AppleMusicSongReference(
            itemID: itemID,
            catalogID: identity.catalogID,
            cloudLibraryID: identity.cloudLibraryID,
            musicAppPersistentID: persistent.flatMap(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID:)),
            isInLibrary: true,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle
        )
    }

    private static func batches(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
