import Foundation

enum PlaybackConnectionState: Equatable {
    case disconnected
    case connecting
    case ready(deviceID: String)
    case transferring(deviceID: String)
    case playing(PlaybackNowPlaying)
    case paused(PlaybackNowPlaying?)
    case unavailable(String)
    case error(PlaybackDisplayError)
}

struct PlaybackNowPlaying: Equatable {
    let name: String
    let artists: [String]
    let albumArtURL: URL?
    let durationMilliseconds: Int
    let positionMilliseconds: Int
    let uri: String?

    var artistText: String {
        artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ")
    }

    var progressText: String {
        "\(Self.durationText(milliseconds: positionMilliseconds)) / \(Self.durationText(milliseconds: durationMilliseconds))"
    }

    static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    /// Formats a duration as `M:SS` (no leading zero on minutes), used by the
    /// now-playing scrubber timestamps.
    static func mmss(milliseconds: Int) -> String {
        durationText(milliseconds: milliseconds)
    }

    func with(positionMilliseconds: Int) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: name,
            artists: artists,
            albumArtURL: albumArtURL,
            durationMilliseconds: durationMilliseconds,
            positionMilliseconds: positionMilliseconds,
            uri: uri
        )
    }
}

struct PlaybackDisplayError: Error, Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: PlaybackRecoveryAction?

    static func == (lhs: PlaybackDisplayError, rhs: PlaybackDisplayError) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.recoveryAction == rhs.recoveryAction
    }
}

enum PlaybackRecoveryAction: Equatable {
    case reconnect
    case reauthenticate
    case retryTransfer
}

enum QueueItemSource: Equatable {
    /// From Web Playback SDK `track_window.next_tracks` (immediate).
    case sdk
    /// User explicitly queued (heuristic: appears after SDK prefix in Web API queue).
    case userQueued
    /// From Spotify Web API queue or general upcoming context.
    case upcoming
}

struct QueueItem: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let albumArtURL: URL?
    let durationMilliseconds: Int
    let uri: String?
    let source: QueueItemSource

    init(
        id: String? = nil,
        name: String,
        subtitle: String,
        albumArtURL: URL?,
        durationMilliseconds: Int,
        uri: String?,
        source: QueueItemSource
    ) {
        self.id = id ?? uri ?? UUID().uuidString
        self.name = name
        self.subtitle = subtitle
        self.albumArtURL = albumArtURL
        self.durationMilliseconds = durationMilliseconds
        self.uri = uri
        self.source = source
    }
}

extension QueueItem {
    static func from(track: SpotifyTrack, source: QueueItemSource) -> QueueItem {
        QueueItem(
            name: track.name,
            subtitle: track.artists.joined(separator: ", "),
            albumArtURL: track.albumArtworkURL,
            durationMilliseconds: track.durationMilliseconds,
            uri: track.uri,
            source: source
        )
    }

    static func from(episode: SpotifyEpisode, source: QueueItemSource) -> QueueItem {
        QueueItem(
            name: episode.name,
            subtitle: episode.showName ?? "Podcast",
            albumArtURL: episode.artworkURL,
            durationMilliseconds: episode.durationMilliseconds,
            uri: episode.uri,
            source: source
        )
    }

    static func from(queueItem: SpotifyQueueTrackItem, source: QueueItemSource) -> QueueItem {
        switch queueItem {
        case let .track(track):
            .from(track: track, source: source)
        case let .episode(episode):
            .from(episode: episode, source: source)
        }
    }

    static func from(playback: PlaybackNowPlaying, source: QueueItemSource) -> QueueItem {
        QueueItem(
            name: playback.name,
            subtitle: playback.artistText,
            albumArtURL: playback.albumArtURL,
            durationMilliseconds: playback.durationMilliseconds,
            uri: playback.uri,
            source: source
        )
    }
}

/// Response from `GET /v1/me/player/queue`.
struct SpotifyQueueResponse: Equatable {
    let currentlyPlaying: SpotifyQueueTrackItem?
    let queue: [SpotifyQueueTrackItem]
}

/// Unified track-or-episode slot from the queue endpoint.
enum SpotifyQueueTrackItem: Equatable {
    case track(SpotifyTrack)
    case episode(SpotifyEpisode)
}

enum PlaybackBridgeEvent: Equatable {
    case ready(deviceID: String)
    case notReady(deviceID: String)
    case stateChanged(PlaybackNowPlaying?, isPaused: Bool, nextTracks: [PlaybackNowPlaying])
    case initializationError(String)
    case authenticationError(String)
    case accountError(String)
    case playbackError(String)
    case log(String)
}

enum PlaybackBridgeCommand: String, Equatable {
    case connect
    case disconnect
    case togglePlay
    case pause
    case resume
    case seek
    case next
    case previous
    case playURI
}

enum PlaybackBridgeMessageError: Error, Equatable {
    case invalidEnvelope
    case missingPayload(String)
    case unsupportedEvent(String)
}
