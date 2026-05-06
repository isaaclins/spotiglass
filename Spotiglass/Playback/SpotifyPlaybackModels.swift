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
    /// Album title from Web Playback SDK when available (used for third-party lyrics matching).
    let albumName: String?
    /// Spotify album ID when `album.uri` / Web API album id is available.
    let albumID: String?
    let albumArtURL: URL?
    let durationMilliseconds: Int
    let positionMilliseconds: Int
    let uri: String?

    var artistText: String {
        artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ")
    }

    var artistTapTargets: [ArtistTapTarget] {
        Self.artistTapTargets(fromNames: artists)
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
            albumName: albumName,
            albumID: albumID,
            albumArtURL: albumArtURL,
            durationMilliseconds: durationMilliseconds,
            positionMilliseconds: positionMilliseconds,
            uri: uri
        )
    }

    static func artistTapTargets(fromNames names: [String]) -> [ArtistTapTarget] {
        var seen = Set<String>()
        var targets: [ArtistTapTarget] = []
        for rawName in names {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            targets.append(ArtistTapTarget(id: nil, name: trimmed))
        }
        return targets
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

struct ArtistTapTarget: Equatable, Identifiable {
    let id: String?
    let name: String

    var stableID: String {
        if let id { return "artist-id:\(id)" }
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return "artist-name:\(normalized)"
    }
}

struct AlbumTapTarget: Equatable {
    let id: String?
    let name: String
}

struct QueueItem: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let albumArtURL: URL?
    /// Album title when known (tracks from Web API or merged SDK projection).
    let albumName: String?
    let albumID: String?
    let durationMilliseconds: Int
    let uri: String?
    let source: QueueItemSource
    let artistTapTargets: [ArtistTapTarget]

    init(
        id: String? = nil,
        name: String,
        subtitle: String,
        albumArtURL: URL?,
        albumName: String? = nil,
        albumID: String? = nil,
        durationMilliseconds: Int,
        uri: String?,
        source: QueueItemSource,
        artistTapTargets: [ArtistTapTarget] = []
    ) {
        self.id = id ?? uri ?? UUID().uuidString
        self.name = name
        self.subtitle = subtitle
        self.albumArtURL = albumArtURL
        self.albumName = albumName
        self.albumID = albumID
        self.durationMilliseconds = durationMilliseconds
        self.uri = uri
        self.source = source
        self.artistTapTargets = artistTapTargets
    }
}

extension QueueItem {
    static func from(track: SpotifyTrack, source: QueueItemSource) -> QueueItem {
        QueueItem(
            name: track.name,
            subtitle: track.artists.joined(separator: ", "),
            albumArtURL: track.albumArtworkURL,
            albumName: track.albumName,
            albumID: track.albumID,
            durationMilliseconds: track.durationMilliseconds,
            uri: track.uri,
            source: source,
            artistTapTargets: artistTapTargets(artistRefs: track.artistRefs, fallbackSubtitle: track.artists.joined(separator: ", "))
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
            albumName: playback.albumName,
            albumID: playback.albumID,
            durationMilliseconds: playback.durationMilliseconds,
            uri: playback.uri,
            source: source,
            artistTapTargets: playback.artistTapTargets
        )
    }

    static func artistTapTargets(artistRefs: [SpotifyArtistRef], fallbackSubtitle: String) -> [ArtistTapTarget] {
        if !artistRefs.isEmpty {
            return artistRefs.map { ArtistTapTarget(id: $0.id, name: $0.name) }
        }
        let fallbackNames = fallbackSubtitle
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return PlaybackNowPlaying.artistTapTargets(fromNames: fallbackNames)
    }

    /// Builds a minimal ``PlaybackNowPlaying`` for LRCLIB prefetch (album title is unknown from queue rows).
    func playbackNowPlayingForLyricsPrefetch() -> PlaybackNowPlaying? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistParts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let artists = artistParts.isEmpty ? (trimmed.isEmpty ? ["Unknown artist"] : [trimmed]) : artistParts
        return PlaybackNowPlaying(
            name: name,
            artists: artists,
            albumName: albumName,
            albumID: albumID,
            albumArtURL: albumArtURL,
            durationMilliseconds: max(1, durationMilliseconds),
            positionMilliseconds: 0,
            uri: uri
        )
    }
}

/// Response from `GET /v1/me/player/queue`.
struct SpotifyQueueResponse: Equatable {
    let currentlyPlaying: SpotifyQueueTrackItem?
    let queue: [SpotifyQueueTrackItem]
}

/// Spotify Web API `repeat_state` for the active player (`GET/PUT /v1/me/player` repeat).
enum SpotifyRepeatMode: String, Equatable, Codable {
    case off
    case context
    case track

    /// Cycles the repeat button: off → context → track → off.
    var next: SpotifyRepeatMode {
        switch self {
        case .off: return .context
        case .context: return .track
        case .track: return .off
        }
    }
}

/// Shuffle + repeat from `GET /v1/me/player` (subset of the full player object).
struct SpotifyPlayerTransport: Equatable {
    let shuffle: Bool
    let repeatMode: SpotifyRepeatMode
}

/// A Spotify Connect endpoint from `GET /v1/me/player/devices` or the nested `device` on `GET /v1/me/player`.
struct SpotifyConnectDevice: Equatable, Identifiable {
    let deviceID: String
    let isActive: Bool
    let isRestricted: Bool
    let name: String
    /// Spotify device type string (e.g. `computer`, `smartphone`, `speaker`).
    let type: String
    let volumePercent: Int?

    var id: String { deviceID }
}

/// Shuffle/repeat plus optional active Connect device from `GET /v1/me/player`.
struct SpotifyPlayerSnapshot: Equatable {
    let transport: SpotifyPlayerTransport
    let activeDevice: SpotifyConnectDevice?
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
    case setVolume
}

enum PlaybackBridgeMessageError: Error, Equatable {
    case invalidEnvelope
    case missingPayload(String)
    case unsupportedEvent(String)
}
