import Foundation

/// A single tappable tile/card on the home surface (quick-access grid and the
/// recently-played carousel). `destination` is dispatched by ``HomeView`` to the
/// browser/playback view-models so cards reuse the same navigation as the rest of
/// the app.
struct HomeMediaCard: Equatable, Identifiable {
    enum Destination: Equatable {
        case likedSongs
        case playlist(id: String)
        case album(id: String, title: String, subtitle: String, artworkURL: URL?)
    }

    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let destination: Destination
    /// The artists in `subtitle`, each a link when the service gave its ID (#478).
    let artistRefs: [MusicArtistRef]
    /// What the card's right-click menu acts on; `nil` (Liked Songs) has no menu, as elsewhere.
    let menuTarget: CollectionMenuTarget?

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        destination: Destination,
        artistRefs: [MusicArtistRef] = [],
        menuTarget: CollectionMenuTarget? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.destination = destination
        self.artistRefs = artistRefs
        self.menuTarget = menuTarget
    }

    /// Builds an album-keyed "jump back in" card from a recently-played track.
    /// Returns `nil` for tracks without album info (local files, podcasts).
    init?(recentlyPlayed track: MusicTrack) {
        guard let albumID = track.albumID else { return nil }
        let title = track.albumName ?? track.name
        let subtitle = track.artists.joined(separator: ", ")
        self.init(
            id: albumID,
            title: title,
            subtitle: subtitle,
            artworkURL: track.albumArtworkURL,
            destination: .album(id: albumID, title: title, subtitle: subtitle, artworkURL: track.albumArtworkURL),
            artistRefs: track.artistRefs,
            menuTarget: .pinnable(.album(MusicAlbum(
                id: albumID,
                name: title,
                artists: track.artists,
                imageURL: track.albumArtworkURL,
                uri: Self.albumURI(id: albumID, siblingURI: track.uri)
            )))
        )
    }

    /// A search result album, linking its artists when the service named them by ID.
    init(album: MusicAlbum) {
        let subtitle = album.artists.joined(separator: ", ")
        self.init(
            id: album.id,
            title: album.name,
            subtitle: subtitle,
            artworkURL: album.imageURL,
            destination: .album(id: album.id, title: album.name, subtitle: subtitle, artworkURL: album.imageURL),
            artistRefs: album.artistRefs,
            menuTarget: .pinnable(.album(album))
        )
    }

    /// A playlist tile or card: Home's quick access and search results.
    init(playlist: MusicPlaylistSummary, subtitle: String) {
        self.init(
            id: playlist.id,
            title: playlist.name,
            subtitle: subtitle,
            artworkURL: playlist.imageURL,
            destination: .playlist(id: playlist.id),
            menuTarget: .playlist(playlist)
        )
    }

    /// The album's URI in the same service as one of its tracks (`spotify:` or `applemusic:`).
    static func albumURI(id: String, siblingURI: String) -> String {
        let scheme = siblingURI.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "spotify"
        return "\(scheme):album:\(id)"
    }
}

/// Loading lifecycle for an individual home section. Separate from
/// ``BrowsingLoadState`` because home sections have an extra terminal state —
/// `unavailable` — for the case where the current token lacks the scope the
/// section needs (the user signed in before the home-feed scopes were added).
/// That renders an inline "Reconnect Spotify" hint rather than an error.
enum HomeSectionState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case unavailable
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }
}
