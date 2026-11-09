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
        return MusicTrack(
            id: song.id.rawValue,
            name: song.title,
            artists: artistNames(song.artistName),
            artistRefs: artistRefs(song.artists),
            albumArtworkURL: artworkURL(song.artwork, size: ArtworkSize.row, pinKind: .track, itemID: song.id),
            albumName: song.albumTitle,
            albumID: song.albums?.first?.id.rawValue,
            durationMilliseconds: milliseconds(song.duration),
            isExplicit: song.contentRating == .explicit,
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
    /// `hasGeneratedCover` drops the cover Apple generates for a playlist without one of its own
    /// (a gradient with the name printed small), so the app's calm placeholder shows instead (#444).
    static func playlistSummary(
        _ playlist: Playlist,
        fallbackOwnerName: String,
        cachedTrackCount: Int? = nil,
        hasGeneratedCover: Bool = false
    ) -> MusicPlaylistSummary {
        // Playlists the user made have no curator; Apple's own and shared ones name theirs.
        let curator = playlist.curatorName
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // A blank name would read as a broken response to the browser's playlist check (built
        // for Spotify's error items) and fail the whole library with a Spotify-style error.
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicPlaylistSummary(
            id: playlist.id.rawValue,
            name: name.isEmpty ? SpotiglassL10n.string("appleMusic.playlist.untitled") : playlist.name,
            ownerID: curator ?? AppleMusicBrowsingProvider.libraryUserID,
            ownerName: curator ?? fallbackOwnerName,
            imageURL: hasGeneratedCover
                ? nil
                : artworkURL(playlist.artwork, size: ArtworkSize.cover, pinKind: .playlist, itemID: playlist.id),
            trackCount: playlist.tracks?.count ?? cachedTrackCount,
            snapshotID: playlistSnapshotID
        )
    }

    /// The catalog ID a shared library playlist carries in its play parameters (`catalogId` from
    /// the local library, `globalId` from the API), to match it with the API's cover (#444).
    static func globalID(of playlist: Playlist) -> String? {
        guard let parameters = playlist.playParameters,
              let data = try? JSONEncoder().encode(parameters),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["catalogId"] ?? object["globalId"]) as? String
    }

    static func album(_ album: Album) -> MusicAlbum {
        MusicAlbum(
            id: album.id.rawValue,
            name: album.title,
            artists: artistNames(album.artistName),
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
        MusicArtist(
            id: artist.id.rawValue,
            name: artist.name,
            imageURL: artworkURL(artist.artwork, size: ArtworkSize.cover, pinKind: .artist, itemID: artist.id),
            uri: uri(kind: "artist", id: artist.id)
        )
    }

    static func artistDetail(_ artist: Artist) -> MusicArtistDetail {
        MusicArtistDetail(
            id: artist.id.rawValue,
            name: artist.name,
            imageURL: artworkURL(artist.artwork, size: ArtworkSize.cover, pinKind: .artist, itemID: artist.id),
            followersTotal: nil,
            genres: artist.genreNames ?? [],
            uri: uri(kind: "artist", id: artist.id)
        )
    }

    // MARK: - Helpers

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
