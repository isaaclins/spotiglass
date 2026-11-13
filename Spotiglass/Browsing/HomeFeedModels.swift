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
    /// Looked up when shown: a recently-played card keeps "Unknown album" or "Unknown artist"
    /// for a nameless one, which follows a language switch like the rest of Home (#548).
    private let titleText: LocalizedText
    private let subtitleText: LocalizedText
    var title: String { titleText.string }
    var subtitle: String { subtitleText.string }
    let artworkURL: URL?
    private let builtDestination: Destination
    /// Where a tap goes. An album opens with the card's title and artists as they read now.
    var destination: Destination {
        guard case let .album(id, _, _, artworkURL) = builtDestination else { return builtDestination }
        return .album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
    }
    /// The artists in `subtitle`, as the service named them.
    let artistNames: [String]
    /// The artists in `subtitle` the service gave an ID for, each a link (#478).
    let artistRefs: [MusicArtistRef]
    /// What the card's right-click menu acts on; `nil` (Liked Songs) has no menu, as elsewhere.
    let menuTarget: CollectionMenuTarget?

    init(
        id: String,
        title: @autoclosure @escaping () -> String,
        subtitle: @autoclosure @escaping () -> String,
        artworkURL: URL?,
        destination: Destination,
        artistNames: [String] = [],
        artistRefs: [MusicArtistRef] = [],
        menuTarget: CollectionMenuTarget? = nil
    ) {
        self.id = id
        self.titleText = LocalizedText(title())
        self.subtitleText = LocalizedText(subtitle())
        self.artworkURL = artworkURL
        self.builtDestination = destination
        self.artistNames = artistNames
        self.artistRefs = artistRefs
        self.menuTarget = menuTarget
    }

    /// Builds an album-keyed "jump back in" card from a recently-played track.
    /// Returns `nil` for tracks without album info (local files, podcasts).
    init?(recentlyPlayed track: MusicTrack) {
        guard let albumID = track.albumID else { return nil }
        // An album without a name is called one in the app's language, not after the track (#547).
        let albumName = track.albumName ?? ""
        self.init(
            id: albumID,
            title: UnnamedMusicItem.displayName(albumName, kind: .album),
            subtitle: track.artists.joined(separator: ", "),
            artworkURL: track.albumArtworkURL,
            // The card's own title and artists replace these when it is tapped.
            destination: .album(id: albumID, title: "", subtitle: "", artworkURL: track.albumArtworkURL),
            artistNames: track.artists,
            artistRefs: track.artistRefs,
            menuTarget: .pinnable(.album(MusicAlbum(
                id: albumID,
                name: albumName,
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
            artistNames: album.artists,
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

    /// The artist line under the card: each artist with an ID is a link, the rest plain names.
    var artistCredits: [HomeArtistCredit] {
        HomeArtistCredit.credits(names: artistNames, refs: artistRefs)
    }

    /// The album's URI in the same service as one of its tracks (`spotify:` or `applemusic:`).
    static func albumURI(id: String, siblingURI: String) -> String {
        let scheme = siblingURI.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "spotify"
        return "\(scheme):album:\(id)"
    }
}

/// One artist under a card: a link when the service gave the artist's ID, else plain text.
enum HomeArtistCredit: Equatable {
    case link(MusicArtistRef)
    case name(String)

    static func credits(names: [String], refs: [MusicArtistRef]) -> [HomeArtistCredit] {
        guard !refs.isEmpty else { return names.map(HomeArtistCredit.name) }
        // Apple Music names every artist in one string ("A & B") and lists them apart by ID,
        // so its IDs are the whole line.
        guard names.count > 1 else { return refs.map(HomeArtistCredit.link) }
        // Spotify names each artist; one without an ID (a local file's) stays as plain text
        // instead of dropping out of the line.
        var unmatched = refs
        return names.map { name in
            // A nameless artist's stand-in was taken in the language of the moment; the ref's
            // follows the app's, so after a switch they match as stand-ins, not as text (#548).
            guard let index = unmatched.firstIndex(where: {
                $0.name == name
                    || (UnnamedMusicItem.isStandIn($0.name, kind: .artist) && UnnamedMusicItem.isStandIn(name, kind: .artist))
            }) else { return .name(name) }
            return .link(unmatched.remove(at: index))
        }
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
    /// Looked up when shown, so a failed section follows a language switch (#548).
    case failed(LocalizedText)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }
}
