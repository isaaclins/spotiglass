import Foundation

struct TrackRowViewModel: Equatable, Identifiable {
    let id: String
    /// 1-based row index in playlist / artist track lists (for ``TrackListRow``).
    let listPosition: Int
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    let badgeText: String?
    let isUnavailable: Bool
    let playableURI: String?
    let artistRefs: [SpotifyArtistRef]

    /// Builds playlist rows with stable numbering without allocating `enumerated()` in SwiftUI bodies.
    static func numberedPlaylistRows(_ items: [SpotifyPlaylistTrackItem]) -> [TrackRowViewModel] {
        items.enumerated().map { index, item in
            TrackRowViewModel(item, listPosition: index + 1)
        }
    }

    /// Builds artist (or album) top-track rows with stable numbering.
    static func numberedTopTracks(_ tracks: [SpotifyTrack]) -> [TrackRowViewModel] {
        tracks.enumerated().map { index, track in
            TrackRowViewModel(topTrack: track, listPosition: index + 1)
        }
    }

    init(_ item: SpotifyPlaylistTrackItem, listPosition: Int) {
        self.listPosition = listPosition
        self.id = item.id

        switch item.content {
        case let .track(track):
            self.title = track.name
            self.subtitle = track.artists.joined(separator: ", ")
            self.artworkURL = track.albumArtworkURL
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
            self.isUnavailable = track.isPlayable == false
            self.playableURI = track.isPlayable == false ? nil : track.uri
            self.artistRefs = track.artistRefs
        case let .episode(episode):
            self.title = episode.name
            self.subtitle = episode.showName ?? "Podcast episode"
            self.artworkURL = episode.artworkURL
            self.durationText = Self.durationText(milliseconds: episode.durationMilliseconds)
            self.badgeText = episode.isPlayable == false ? "Unavailable episode" : "Episode"
            self.isUnavailable = episode.isPlayable == false
            self.playableURI = episode.isPlayable == false ? nil : episode.uri
            self.artistRefs = []
        case let .localTrack(track):
            self.title = track.name
            self.subtitle = track.artists.isEmpty ? "Local track" : track.artists.joined(separator: ", ")
            self.artworkURL = nil
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = "Local"
            self.isUnavailable = false
            self.playableURI = nil
            self.artistRefs = []
        case let .unavailable(reason):
            self.title = "Unavailable item"
            self.subtitle = reason
            self.artworkURL = nil
            self.durationText = "--:--"
            self.badgeText = "Unavailable"
            self.isUnavailable = true
            self.playableURI = nil
            self.artistRefs = []
        }
    }

    init(topTrack track: SpotifyTrack, listPosition: Int) {
        self.listPosition = listPosition
        self.id = track.id
        self.title = track.name
        self.subtitle = track.artists.joined(separator: ", ")
        self.artworkURL = track.albumArtworkURL
        self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
        self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
        self.isUnavailable = track.isPlayable == false
        self.playableURI = track.isPlayable == false ? nil : track.uri
        self.artistRefs = track.artistRefs
    }

    private static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    /// Milliseconds parsed from ``durationText`` (`m:ss`); `0` when unparsable.
    var durationMillisecondsForPinning: Int {
        let parts = durationText.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let s = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(0, (m * 60 + s) * 1_000)
    }

    /// Domain track for palette pinning and draggable pins; `nil` for episodes, locals, and unavailable rows.
    func spotifyTrackForPinning() -> SpotifyTrack? {
        guard let playableURI, playableURI.hasPrefix("spotify:track:") else { return nil }
        let names: [String] = artistRefs.map(\.name).isEmpty
            ? subtitle.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            : artistRefs.map(\.name)
        return SpotifyTrack(
            id: id,
            name: title,
            artists: names,
            artistRefs: artistRefs,
            albumArtworkURL: artworkURL,
            durationMilliseconds: durationMillisecondsForPinning,
            isExplicit: badgeText == "Explicit",
            isPlayable: !isUnavailable,
            linkedFromID: nil,
            uri: playableURI
        )
    }

    func pinnedTrackItem(originPlaylistID: String?) -> PinnedItem? {
        guard let track = spotifyTrackForPinning() else { return nil }
        return .track(track, originPlaylistID: originPlaylistID)
    }
}
