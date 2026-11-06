import Foundation

/// What the Apple Music provider starts. URIs are the `applemusic:<kind>:<id>` references the
/// Apple Music browsing provider hands out.
enum AppleMusicQueueRequest: Equatable {
    /// An explicit list of songs or music videos, starting at `startURI` (the first when nil).
    case items(uris: [String], startURI: String?)
    case album(id: String)
    case playlist(id: String)
    /// An artist's songs: the catalog's top songs, or the songs of a library artist.
    case artist(id: String)
}

/// Shuffle, repeat, the item, the position and what comes next, read from MusicKit's player in
/// service-neutral types.
struct AppleMusicPlayerState: Equatable {
    enum Status: Equatable {
        case playing
        case paused
        /// Stopped, interrupted or never started.
        case stopped
    }

    var status: Status
    /// `nil` when the queue is empty.
    var current: MusicTrack?
    var positionMilliseconds: Int
    var shuffle: Bool
    var repeatMode: MusicRepeatMode
    /// The entries after the current one, in play order.
    var upcoming: [MusicTrack]
}

/// The seam between the provider and MusicKit's `ApplicationMusicPlayer`.
/// ``MusicKitApplicationPlayer`` is the live implementation; tests use a scripted player.
@MainActor
protocol AppleMusicPlayerControlling: AnyObject {
    /// Whether this app may use Apple Music (the system's Media & Apple Music permission).
    func isAuthorized() -> Bool
    /// Replaces the queue and starts playing it.
    func play(_ request: AppleMusicQueueRequest) async throws
    func pause()
    func resume() async throws
    /// Stops playback and keeps the queue.
    func stop()
    func seek(toMilliseconds milliseconds: Int)
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setShuffle(_ enabled: Bool)
    func setRepeat(_ mode: MusicRepeatMode)
    /// Adds an item after the current one and after the items added before it, like
    /// Spotify's "Add to queue".
    func enqueue(uri: String) async throws
    func readState() -> AppleMusicPlayerState
}

/// Apple Music behind ``MusicPlaybackProvider``, played by MusicKit's `ApplicationMusicPlayer`.
///
/// There is one player, this Mac, so it reports one constant device id, has no device
/// transfer, nothing to reload and no pushed state: the session reads the player on its poll
/// cadence and confirms commands with the settle window from ``MusicPlaybackCapabilities``.
/// Apple's player publishes Now Playing (Control Center, media keys) itself, so this provider
/// never writes `MPNowPlayingInfoCenter`.
///
/// MusicKit has no volume for the application player, so the provider does not declare
/// ``MusicPlaybackCapabilities/playerVolume`` and the volume slider is hidden; the Mac's own
/// volume applies.
@MainActor
final class AppleMusicPlaybackProvider: MusicPlaybackProvider {
    /// The one in-app player's id. Opaque to the session.
    static let deviceID = "apple-music-this-mac"

    let capabilities: MusicPlaybackCapabilities = []
    var eventHandler: ((MusicPlaybackEventEnvelope) -> Void)?

    private let player: any AppleMusicPlayerControlling

    init(player: (any AppleMusicPlayerControlling)? = nil) {
        self.player = player ?? MusicKitApplicationPlayer()
    }

    // MARK: - Player lifecycle

    func loadPlayer(generation: PlaybackHostGeneration) {}

    func connectPlayer(generation: PlaybackHostGeneration) async throws {
        guard player.isAuthorized() else {
            throw MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: "Apple Music access is off")
        }
        eventHandler?(MusicPlaybackEventEnvelope(event: .ready(deviceID: Self.deviceID), hostGeneration: generation))
    }

    func disconnectPlayer(generation: PlaybackHostGeneration) async throws {
        player.stop()
    }

    // MARK: - Commands for a device

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws {
        try await perform { try await player.play(Self.queueRequest(for: request)) }
    }

    func pause(deviceID: String) async throws {
        player.pause()
    }

    func resume(deviceID: String) async throws {
        try await perform { try await player.resume() }
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        player.seek(toMilliseconds: max(0, milliseconds))
    }

    func skipToNext(deviceID: String) async throws {
        try await perform { try await player.skipToNext() }
    }

    func skipToPrevious(deviceID: String) async throws {
        try await perform { try await player.skipToPrevious() }
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        player.setShuffle(enabled)
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        player.setRepeat(mode)
    }

    func enqueue(uri: String, deviceID: String) async throws {
        try await perform { try await player.enqueue(uri: uri) }
    }

    // MARK: - Commands for the in-app player

    /// The session uses explicit pause / resume for a player without pushed state; this is
    /// only reached by callers that toggle directly.
    func togglePlayPause() async throws {
        if player.readState().status == .playing {
            player.pause()
        } else {
            try await perform { try await player.resume() }
        }
    }

    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws {}

    // MARK: - Reads

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
        let state = player.readState()
        guard let current = state.current else { return nil }
        return MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: state.shuffle, repeatMode: state.repeatMode),
            activeDevice: nil,
            isPlaying: state.status == .playing,
            item: .track(current),
            progressMilliseconds: state.positionMilliseconds
        )
    }

    func fetchQueue() async throws -> MusicPlaybackQueue {
        MusicPlaybackQueue(queue: player.readState().upcoming.map { .track($0) })
    }

    // MARK: - Mapping

    /// Which MusicKit queue a play request becomes. Context URIs name their kind; anything
    /// that isn't an Apple Music reference can't be played here.
    static func queueRequest(for request: MusicPlaybackRequest) throws -> AppleMusicQueueRequest {
        switch request {
        case let .item(uri):
            guard reference(uri) != nil else { throw notPlayable(uri) }
            return .items(uris: [uri], startURI: uri)
        case let .items(uris, startURI):
            let playable = uris.filter { reference($0) != nil }
            guard !playable.isEmpty else { throw notPlayable(startURI ?? uris.first ?? "") }
            return .items(uris: playable, startURI: startURI.flatMap { playable.contains($0) ? $0 : nil })
        case let .context(uri):
            guard let (kind, id) = reference(uri) else { throw notPlayable(uri) }
            switch kind {
            case "album": return .album(id: id)
            case "playlist": return .playlist(id: id)
            case "artist": return .artist(id: id)
            case "song", "music-video", "track": return .items(uris: [uri], startURI: uri)
            default: throw notPlayable(uri)
            }
        }
    }

    /// `(kind, id)` of an `applemusic:<kind>:<id>` URI.
    static func reference(_ uri: String) -> (kind: String, id: String)? {
        let parts = uri.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == AppleMusicItemMapping.uriScheme, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    private static func notPlayable(_ uri: String) -> MusicPlaybackError {
        MusicPlaybackError(service: .appleMusic, reason: .notFound, detail: "Not an Apple Music item: \(uri)")
    }

    /// Every failure leaves this provider as a ``MusicPlaybackError`` naming Apple Music.
    private func perform(_ command: () async throws -> Void) async throws {
        do {
            try await command()
        } catch let error as MusicPlaybackError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
        }
    }
}
