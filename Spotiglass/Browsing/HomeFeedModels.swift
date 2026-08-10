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

    init(id: String, title: String, subtitle: String, artworkURL: URL?, destination: Destination) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.destination = destination
    }

    /// Builds an album-keyed "jump back in" card from a recently-played track.
    /// Returns `nil` for tracks without album info (local files, podcasts).
    init?(recentlyPlayed track: SpotifyTrack) {
        guard let albumID = track.albumID else { return nil }
        self.id = albumID
        self.title = track.albumName ?? track.name
        self.subtitle = track.artists.joined(separator: ", ")
        self.artworkURL = track.albumArtworkURL
        self.destination = .album(
            id: albumID,
            title: track.albumName ?? track.name,
            subtitle: track.artists.joined(separator: ", "),
            artworkURL: track.albumArtworkURL
        )
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
        if case .loaded(let value) = self { return value }
        return nil
    }
}
