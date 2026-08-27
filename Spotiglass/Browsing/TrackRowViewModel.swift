import Foundation

struct TrackRowViewModel: Equatable, Identifiable {
    let id: String
    /// Canonical Spotify track ID. Playlist rows keep ``id`` occurrence-qualified
    /// for selection, so pinning and badge state use this separate identity.
    let spotifyTrackID: String?
    /// 1-based row index in playlist / artist track lists (for ``TrackListRow``).
    let listPosition: Int
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    /// Carried as a number so nothing has to read the length back out of its own
    /// display text (#159).
    let durationMilliseconds: Int
    let badgeText: String?
    let isUnavailable: Bool
    /// Tracked alongside ``badgeText`` so pin/queue paths can recognise explicit
    /// tracks after the badge string is localized.
    let isExplicit: Bool
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
            self.spotifyTrackID = PinnedItem.canonicalTrackID(for: track)
            self.title = track.name
            self.subtitle = track.artists.joined(separator: ", ")
            self.artworkURL = track.albumArtworkURL
            self.durationText = TrackDuration.text(milliseconds: track.durationMilliseconds)
            self.durationMilliseconds = max(0, track.durationMilliseconds)
            self.badgeText = track.isPlayable == false
                ? SpotiglassL10n.string("browser.trackBadge.unavailable")
                : (track.isExplicit ? SpotiglassL10n.string("browser.trackBadge.explicit") : nil)
            self.isUnavailable = track.isPlayable == false
            self.isExplicit = track.isExplicit
            self.playableURI = track.isPlayable == false ? nil : track.uri
            self.artistRefs = track.artistRefs
        case let .episode(episode):
            self.spotifyTrackID = nil
            self.title = episode.name
            self.subtitle = episode.showName ?? SpotiglassL10n.string("browser.trackBadge.podcastEpisode")
            self.artworkURL = episode.artworkURL
            self.durationText = TrackDuration.text(milliseconds: episode.durationMilliseconds)
            self.durationMilliseconds = max(0, episode.durationMilliseconds)
            self.badgeText = episode.isPlayable == false
                ? SpotiglassL10n.string("browser.trackBadge.unavailableEpisode")
                : SpotiglassL10n.string("browser.trackBadge.episode")
            self.isUnavailable = episode.isPlayable == false
            self.isExplicit = false
            self.playableURI = episode.isPlayable == false ? nil : episode.uri
            self.artistRefs = []
        case let .localTrack(track):
            self.spotifyTrackID = nil
            self.title = track.name
            self.subtitle = track.artists.isEmpty
                ? SpotiglassL10n.string("browser.trackBadge.localTrack")
                : track.artists.joined(separator: ", ")
            self.artworkURL = nil
            self.durationText = TrackDuration.text(milliseconds: track.durationMilliseconds)
            self.durationMilliseconds = max(0, track.durationMilliseconds)
            self.badgeText = SpotiglassL10n.string("browser.trackBadge.local")
            self.isUnavailable = false
            self.isExplicit = false
            self.playableURI = nil
            self.artistRefs = []
        case let .unavailable(reason):
            self.spotifyTrackID = nil
            self.title = SpotiglassL10n.string("browser.trackBadge.unavailableItem")
            self.subtitle = reason
            self.artworkURL = nil
            self.durationText = TrackDuration.unknownText
            self.durationMilliseconds = 0
            self.badgeText = SpotiglassL10n.string("browser.trackBadge.unavailable")
            self.isUnavailable = true
            self.isExplicit = false
            self.playableURI = nil
            self.artistRefs = []
        }
    }

    init(topTrack track: SpotifyTrack, listPosition: Int) {
        self.listPosition = listPosition
        self.id = track.id
        self.spotifyTrackID = PinnedItem.canonicalTrackID(for: track)
        self.title = track.name
        self.subtitle = track.artists.joined(separator: ", ")
        self.artworkURL = track.albumArtworkURL
        self.durationText = TrackDuration.text(milliseconds: track.durationMilliseconds)
        self.durationMilliseconds = max(0, track.durationMilliseconds)
        self.badgeText = track.isPlayable == false
            ? SpotiglassL10n.string("browser.trackBadge.unavailable")
            : (track.isExplicit ? SpotiglassL10n.string("browser.trackBadge.explicit") : nil)
        self.isUnavailable = track.isPlayable == false
        self.isExplicit = track.isExplicit
        self.playableURI = track.isPlayable == false ? nil : track.uri
        self.artistRefs = track.artistRefs
    }

    /// Projects a queue item into the row shape used by the shared Spotify
    /// mutation menu. Queue occurrences have their own IDs, so the catalog
    /// track ID is derived from the URI instead.
    init(queueItem item: QueueItem, listPosition: Int = 1) {
        self.listPosition = listPosition
        self.id = item.id
        let uri = item.playableURI
        if let uri, uri.hasPrefix("spotify:track:") {
            let trackID = String(uri.dropFirst("spotify:track:".count))
            self.spotifyTrackID = trackID.isEmpty ? nil : trackID
        } else {
            self.spotifyTrackID = nil
        }
        self.title = item.name
        self.subtitle = item.subtitle
        self.artworkURL = item.albumArtURL
        self.durationText = TrackDuration.text(milliseconds: item.durationMilliseconds)
        self.durationMilliseconds = max(0, item.durationMilliseconds)
        self.badgeText = uri?.hasPrefix("spotify:episode:") == true
            ? SpotiglassL10n.string("browser.trackBadge.episode")
            : nil
        self.isUnavailable = uri == nil
        self.isExplicit = false
        self.playableURI = uri
        self.artistRefs = item.artistTapTargets.compactMap { target in
            guard let id = target.id else { return nil }
            return SpotifyArtistRef(id: id, name: target.name)
        }
    }

    /// Domain track for palette pinning and draggable pins; `nil` for episodes, locals, and unavailable rows.
    func spotifyTrackForPinning() -> SpotifyTrack? {
        guard let spotifyTrackID,
              let playableURI,
              playableURI.hasPrefix("spotify:track:") else { return nil }
        let names: [String] = artistRefs.map(\.name).isEmpty
            ? subtitle.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            : artistRefs.map(\.name)
        return SpotifyTrack(
            id: spotifyTrackID,
            name: title,
            artists: names,
            artistRefs: artistRefs,
            albumArtworkURL: artworkURL,
            durationMilliseconds: durationMilliseconds,
            isExplicit: isExplicit,
            isPlayable: !isUnavailable,
            linkedFromID: nil,
            uri: playableURI
        )
    }

    func pinnedTrackItem() -> PinnedItem? {
        guard let track = spotifyTrackForPinning() else { return nil }
        return .track(track)
    }
}
