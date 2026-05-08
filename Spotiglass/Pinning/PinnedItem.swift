import Foundation

/// Kind of Spotify entity (or virtual entity) that can live in the pinned area
/// of the sidebar.
enum PinnedItemKind: String, Codable, Equatable, CaseIterable {
    case playlist
    case artist
    case album
    case track
    case likedSongs
}

/// One pinned row. Tracks pinned from a playlist remember the originating
/// playlist so that follow-up actions can refer back to it; everything else
/// stores the bare metadata needed to render and act on the row even while
/// offline.
struct PinnedItem: Identifiable, Equatable, Codable, Hashable {
    let id: String
    let kind: PinnedItemKind
    var title: String
    var subtitle: String
    var artworkURL: URL?
    /// `spotify:<kind>:<id>` for real Spotify entities; `nil` for virtual rows
    /// like Liked Songs which have no list-level URI.
    let spotifyURI: String?
    var isStale: Bool

    /// ID for the Liked Songs virtual row. Stable across processes / accounts;
    /// duplicated only when the same row is pinned for the same account.
    static let likedSongsID = "likedSongs"

    /// Stable identifier formula for Spotify-backed pins.
    static func id(forKind kind: PinnedItemKind, spotifyID: String) -> String {
        "\(kind.rawValue):\(spotifyID)"
    }
}

extension PinnedItem {
    static func playlist(_ playlist: SpotifyPlaylistSummary) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .playlist, spotifyID: playlist.id),
            kind: .playlist,
            title: playlist.name,
            subtitle: playlist.ownerName,
            artworkURL: playlist.imageURL,
            spotifyURI: "spotify:playlist:\(playlist.id)",
            isStale: false
        )
    }

    static func artist(_ artist: SpotifyArtistDetail) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .artist, spotifyID: artist.id),
            kind: .artist,
            title: artist.name,
            subtitle: "Artist",
            artworkURL: artist.imageURL,
            spotifyURI: artist.uri,
            isStale: false
        )
    }

    /// Convenience for palette artist hits where we only have the lighter ``SpotifyArtist``.
    static func artist(_ artist: SpotifyArtist) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .artist, spotifyID: artist.id),
            kind: .artist,
            title: artist.name,
            subtitle: "Artist",
            artworkURL: artist.imageURL,
            spotifyURI: artist.uri,
            isStale: false
        )
    }

    static func album(_ album: SpotifyArtistAlbum) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .album, spotifyID: album.id),
            kind: .album,
            title: album.name,
            subtitle: album.releaseYear ?? "Album",
            artworkURL: album.imageURL,
            spotifyURI: album.uri,
            isStale: false
        )
    }

    static func album(_ album: SpotifyAlbum) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .album, spotifyID: album.id),
            kind: .album,
            title: album.name,
            subtitle: album.artists.joined(separator: ", "),
            artworkURL: album.imageURL,
            spotifyURI: album.uri,
            isStale: false
        )
    }

    static func track(_ track: SpotifyTrack) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .track, spotifyID: track.id),
            kind: .track,
            title: track.name,
            subtitle: track.artists.joined(separator: ", "),
            artworkURL: track.albumArtworkURL,
            spotifyURI: track.uri,
            isStale: false
        )
    }

    static func likedSongs(ownerDisplay: String, artworkURL: URL?) -> PinnedItem {
        PinnedItem(
            id: PinnedItem.likedSongsID,
            kind: .likedSongs,
            title: "Liked Songs",
            subtitle: ownerDisplay,
            artworkURL: artworkURL,
            spotifyURI: nil,
            isStale: false
        )
    }
}

extension PinnedItem {
    /// Spotify-side identifier for `kind` items (`nil` for the virtual Liked
    /// Songs row, which has no Spotify entity backing the list itself).
    var spotifyID: String? {
        if id == PinnedItem.likedSongsID { return nil }
        let prefix = "\(kind.rawValue):"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}
