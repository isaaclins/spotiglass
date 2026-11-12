import Foundation
import MusicKit

/// Maps MusicKit items onto the service-neutral `Music*` models.
///
/// `id` is MusicKit's own item ID (catalog IDs are numeric, library IDs start with `i.`, `l.`
/// or `p.`), and `uri` is an `applemusic:<kind>:<id>` reference that only the Apple Music
/// provider interprets. Neither is ever parsed outside this provider.
enum AppleMusicItemMapping {
    static let uriScheme = "applemusic"
    /// Accepted by every Apple Music playlist; there is no snapshot concept, so the cache keys
    /// a playlist's tracks by this constant and relies on its age instead.
    static let playlistSnapshotID = "applemusic"

    /// Pixel sizes the mapped URLs carry. Views ask for the size they draw through
    /// `AppleMusicArtworkRegistry.sizedURL`, so a track's row-sized URL still gets a sharp
    /// cover on a Home card or in Lyrics (#426).
    enum ArtworkSize {
        static let row = 120
        static let cover = 600
    }

    /// "You" for a playlist in the user's own Apple Music library, in `locale`. Rows and pins keep
    /// the owner they were built with, which may be in another language (a pin saved before a
    /// language switch), so it is resolved again where it is shown (#398).
    static func localizedOwnerName(_ stored: String, ownerID: String?, locale: Locale) -> String {
        guard ownerID == AppleMusicBrowsingProvider.libraryUserID else { return stored }
        return SpotiglassL10n.string("appleMusic.library.owner", locale: locale)
    }

    static func uri(kind: String, id: MusicItemID) -> String {
        "\(uriScheme):\(kind):\(id.rawValue)"
    }

    /// `pinKind` and `itemID` name the item in pins (`PinnedItem.id`), so a pin saved last
    /// session can find this session's library cover.
    static func artworkURL(
        _ artwork: Artwork?,
        size: Int,
        pinKind: PinnedItemKind? = nil,
        itemID: MusicItemID? = nil,
        registry: AppleMusicArtworkRegistry = .shared
    ) -> URL? {
        guard let artwork, let url = artwork.url(width: size, height: size) else { return nil }
        // Catalog artwork is registered too, so views can ask for the size they draw (#426).
        let key = pinKind.flatMap { kind in
            itemID.map { PinnedItem.id(forKind: kind, spotifyID: $0.rawValue) }
        }
        registry.register(artwork, for: url, itemKey: key)
        return url
    }

    // MARK: - Tracks

    static func track(_ song: Song) -> MusicTrack {
        let uri = uri(kind: "song", id: song.id)
        // Playback queues this exact song for the row (see AppleMusicPlayableRegistry).
        AppleMusicPlayableRegistry.shared.register(song, for: uri)
        registerPinAlias(.track, song)
        return MusicTrack(
            id: song.id.rawValue,
            name: song.title,
            artists: artistNames(song.artistName),
            artistRefs: artistRefs(song.artists),
            albumArtworkURL: artworkURL(song.artwork, size: ArtworkSize.row, pinKind: .track, itemID: song.id),
            albumName: song.albumTitle,
            albumID: song.albums?.first?.id.rawValue,
            durationMilliseconds: milliseconds(song.duration),
            // Saved songs have no rating of their own on macOS; their catalog release's counts (#518).
            isExplicit: AppleMusicContentRatings.shared.isExplicit(song),
            isPlayable: song.playParameters != nil,
            linkedFromID: nil,
            uri: uri
        )
    }

    static func track(_ track: Track, album: Album? = nil) -> MusicTrack {
        switch track {
        case let .song(song):
            let mapped = Self.track(song)
            guard let album else { return mapped }
            return mapped.withAlbum(album)
        case let .musicVideo(video):
            return MusicTrack(
                id: video.id.rawValue,
                name: video.title,
                artists: artistNames(video.artistName),
                albumArtworkURL: artworkURL(video.artwork ?? album?.artwork, size: ArtworkSize.row),
                albumName: video.albumTitle ?? album?.title,
                albumID: album?.id.rawValue,
                durationMilliseconds: milliseconds(video.duration),
                isExplicit: video.contentRating == .explicit,
                // MusicKit's player can't queue music videos on macOS, so their rows show as
                // unavailable instead of starting another song when clicked.
                isPlayable: false,
                linkedFromID: nil,
                uri: uri(kind: "music-video", id: video.id)
            )
        @unknown default:
            return MusicTrack(
                id: track.id.rawValue,
                name: track.title,
                artists: artistNames(track.artistName),
                albumArtworkURL: artworkURL(track.artwork, size: ArtworkSize.row),
                durationMilliseconds: milliseconds(track.duration),
                isExplicit: track.contentRating == .explicit,
                isPlayable: track.playParameters != nil,
                linkedFromID: nil,
                uri: uri(kind: "track", id: track.id)
            )
        }
    }

    static func playlistItems(_ tracks: [MusicTrack]) -> [MusicPlaylistTrackItem] {
        tracks.enumerated().map { index, track in
            // Positions keep repeated songs in one playlist distinct for SwiftUI lists.
            MusicPlaylistTrackItem(id: "\(index)-\(track.id)", content: .track(track))
        }
    }

    // MARK: - Collections

    /// `cachedTrackCount` stands in when MusicKit lists the playlist without its tracks, which
    /// library listings always do.
    /// The cover is the one the Music app shows, also the one Apple generates for a playlist
    /// without a picture of its own (#477).
    /// `catalogCopy` is the catalog playlist a saved one is a copy of, when the caller has it: its
    /// cover loads without the library (#524).
    static func playlistSummary(
        _ playlist: Playlist,
        fallbackOwnerName: String,
        cachedTrackCount: Int? = nil,
        catalogCopy: Playlist? = nil
    ) -> MusicPlaylistSummary {
        // Playlists the user made have no curator; Apple's own and shared ones name theirs.
        let curator = playlist.curatorName
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let cover = catalogCopy.flatMap { $0.id == playlist.id ? nil : $0.artwork } ?? playlist.artwork
        let imageURL = artworkURL(cover, size: ArtworkSize.cover, pinKind: .playlist, itemID: playlist.id)
        // Search lists a shared library playlist under its catalog ID too, and pins made there
        // carry that ID, so the cover is also kept under it: such a pin draws it after a relaunch,
        // and one saved without a cover gets it from the library listing (#477).
        if let imageURL, let artwork = cover, let catalogID = catalogID(of: playlist),
           catalogID != playlist.id.rawValue {
            AppleMusicArtworkRegistry.shared.register(
                artwork, for: imageURL, itemKey: PinnedItem.id(forKind: .playlist, spotifyID: catalogID)
            )
        }
        AppleMusicPinAliasRegistry.shared.register(kind: .playlist, itemID: playlist.id.rawValue) {
            catalogID(of: playlist)
        }
        return MusicPlaylistSummary(
            id: playlist.id.rawValue,
            // A blank name reads as "Untitled Playlist" in the app's language (#547), so the
            // browser's playlist check (built for Spotify's error items) never sees it blank.
            name: playlist.name,
            ownerID: curator ?? AppleMusicBrowsingProvider.libraryUserID,
            ownerName: curator ?? fallbackOwnerName,
            imageURL: imageURL,
            trackCount: playlist.tracks?.count ?? cachedTrackCount,
            snapshotID: playlistSnapshotID
        )
    }

    /// The catalog ID a shared library playlist carries in its play parameters (`catalogId` from
    /// the local library, `globalId` from the API).
    static func catalogID(of playlist: Playlist) -> String? {
        guard let parameters = playlist.playParameters,
              let data = try? JSONEncoder().encode(parameters),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["catalogId"] ?? object["globalId"]) as? String
    }

    /// What says "same playlist" across the library and the catalog: the catalog ID a saved
    /// playlist carries (the one pins pair it by), else the playlist's own ID (a playlist the
    /// user made, a catalog one).
    static func playlistMatchID(_ playlist: Playlist) -> String {
        catalogID(of: playlist) ?? playlist.id.rawValue
    }

    static func album(_ album: Album) -> MusicAlbum {
        registerAlbumPin(album)
        return MusicAlbum(
            id: album.id.rawValue,
            name: album.title,
            artists: artistNames(album.artistName),
            artistRefs: artistRefs(album.artists),
            imageURL: artworkURL(album.artwork, size: ArtworkSize.cover, pinKind: .album, itemID: album.id),
            uri: uri(kind: "album", id: album.id)
        )
    }

    static func artistAlbum(_ album: Album) -> MusicArtistAlbum {
        let group: MusicArtistAlbumGroup
        if album.isCompilation == true {
            group = .compilation
        } else if album.isSingle == true {
            group = .single
        } else {
            group = .album
        }
        registerAlbumPin(album)
        return MusicArtistAlbum(
            id: album.id.rawValue,
            name: album.title,
            imageURL: artworkURL(album.artwork, size: ArtworkSize.cover, pinKind: .album, itemID: album.id),
            releaseYear: album.releaseDate.map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) },
            totalTracks: album.trackCount,
            group: group,
            uri: uri(kind: "album", id: album.id)
        )
    }

    static func artist(_ artist: Artist) -> MusicArtist {
        registerPinAlias(.artist, artist)
        return MusicArtist(
            id: artist.id.rawValue,
            name: artist.name,
            imageURL: artworkURL(artist.artwork, size: ArtworkSize.cover, pinKind: .artist, itemID: artist.id),
            uri: uri(kind: "artist", id: artist.id)
        )
    }

    static func artistDetail(_ artist: Artist) -> MusicArtistDetail {
        registerPinAlias(.artist, artist)
        return MusicArtistDetail(
            id: artist.id.rawValue,
            name: artist.name,
            imageURL: artworkURL(artist.artwork, size: ArtworkSize.cover, pinKind: .artist, itemID: artist.id),
            followersTotal: nil,
            genres: artist.genreNames ?? [],
            uri: uri(kind: "artist", id: artist.id)
        )
    }

    // MARK: - Helpers

    /// What Search says "same item" by across the library and the catalog, whose IDs differ. A
    /// catalog item goes by its own ID and by `content` (title, artist and rating: a clean and an
    /// explicit version share the rest). A saved item goes by the catalog ID it carries, which
    /// names the very release it is: MusicKit on macOS gives saved songs and albums no rating, so
    /// by content every saved item would be clean, and a saved explicit album would hide its clean
    /// catalog copy and show next to its own explicit one (#512). Only a saved item without a
    /// catalog ID (an upload, say) goes by its content.
    static func searchMatchKeys<Item: MusicItem & Encodable>(
        _ item: Item,
        isSaved: Bool,
        content: (Item) -> String
    ) -> [String] {
        guard isSaved else { return ["catalog:\(item.id.rawValue)", content(item)] }
        // MusicKit writes an item's own ID as its catalog ID when it took the item for a catalog one.
        if let catalogID = AppleMusicSongIdentity(encoding: item).catalogID, catalogID != item.id.rawValue {
            return ["catalog:\(catalogID)"]
        }
        return [content(item)]
    }

    /// An album's content for ``searchMatchKeys(_:isSaved:content:)``: title, artist and rating.
    static func albumContentKey(_ album: Album) -> String {
        "\(album.title)|\(album.artistName)|\(album.contentRating == .explicit)".lowercased()
    }

    /// A song's content for ``searchMatchKeys(_:isSaved:content:)``: title, artist, album and
    /// rating (the same title and artist on another album is another recording).
    static func songContentKey(_ song: Song) -> String {
        "\(song.title)|\(song.artistName)|\(song.albumTitle ?? "")|\(AppleMusicContentRatings.shared.isExplicit(song))".lowercased()
    }

    /// What pins say "same album" by: title and artist. It leaves the rating out, since MusicKit
    /// gives saved albums none on macOS; the release day and track count tell a clean and an
    /// explicit release apart instead (``AppleMusicPinAliasRegistry``).
    static func albumPinKey(_ album: Album) -> String {
        "\(album.title)|\(album.artistName)".lowercased()
    }

    /// Lets a pin of this album find its other copy, library or catalog (#487). A saved album
    /// carries no catalog ID on macOS, so it goes by its match key.
    static func registerAlbumPin(_ album: Album, in registry: AppleMusicPinAliasRegistry = .shared) {
        registry.register(
            albumID: album.id.rawValue, matchKey: albumPinKey(album),
            query: AppleMusicAlbumQuery(title: album.title, artist: album.artistName),
            detail: AppleMusicAlbumDetail(album)
        )
    }

    /// Lets a pin of this library item find its catalog copy and back (#487).
    private static func registerPinAlias<Item: MusicItem & Encodable & Sendable>(_ kind: PinnedItemKind, _ item: Item) {
        AppleMusicPinAliasRegistry.shared.register(kind: kind, itemID: item.id.rawValue) {
            AppleMusicSongIdentity(encoding: item).catalogID
        }
    }

    private static func artistNames(_ name: String?) -> [String] {
        guard let name, !name.isEmpty else { return [] }
        return [name]
    }

    private static func artistRefs(_ artists: MusicItemCollection<Artist>?) -> [MusicArtistRef] {
        guard let artists else { return [] }
        return artists.map { MusicArtistRef(id: $0.id.rawValue, name: $0.name) }
    }

    private static func milliseconds(_ seconds: TimeInterval?) -> Int {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}

private extension MusicTrack {
    /// Album tracks often come without their own artwork or album reference; the album has both.
    func withAlbum(_ album: Album) -> MusicTrack {
        MusicTrack(
            id: id,
            name: name,
            artists: artists,
            artistRefs: artistRefs,
            albumArtworkURL: albumArtworkURL
                ?? AppleMusicItemMapping.artworkURL(album.artwork, size: AppleMusicItemMapping.ArtworkSize.row),
            albumName: albumName ?? album.title,
            albumID: albumID ?? album.id.rawValue,
            durationMilliseconds: durationMilliseconds,
            isExplicit: isExplicit,
            isPlayable: isPlayable,
            linkedFromID: linkedFromID,
            uri: uri
        )
    }
}
