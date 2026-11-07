import Foundation

/// Spotify behind ``MusicPlaybackProvider``: commands and reads go to the Web API
/// (`SpotifyPlaybackControlling`), the in-app player is the Web Playback SDK in a
/// hidden web view (`WebPlaybackCommanding`), and Spotify Connect is the device
/// transfer capability.
///
/// This type only translates; pacing, deduplication, transfer budgets and the
/// SDK recovery choreography stay in the session, so every request Spotify
/// receives is the one it received before the provider existed.
@MainActor
final class SpotifyPlaybackProvider: MusicPlaybackProvider, MusicPlaybackDeviceTransfer {
    let playbackAPI: SpotifyPlaybackControlling
    let webCommander: WebPlaybackCommanding

    var eventHandler: ((MusicPlaybackEventEnvelope) -> Void)?

    let service: MusicService = .spotify
    let capabilities: MusicPlaybackCapabilities = [.pushesPlayerState, .reloadablePlayer, .playerVolume]

    var deviceTransfer: (any MusicPlaybackDeviceTransfer)? { self }

    init(playbackAPI: SpotifyPlaybackControlling, webCommander: WebPlaybackCommanding) {
        self.playbackAPI = playbackAPI
        self.webCommander = webCommander
    }

    /// Entry point for events parsed from the SDK page.
    func deliver(_ envelope: MusicPlaybackEventEnvelope) {
        eventHandler?(envelope)
    }

    // MARK: - Player lifecycle

    func loadPlayer(generation: PlaybackHostGeneration) {
        webCommander.loadHost(generation: generation)
    }

    func connectPlayer(generation: PlaybackHostGeneration) async throws {
        try await webCommander.send(.connect, payload: [:], generation: generation)
    }

    func disconnectPlayer(generation: PlaybackHostGeneration) async throws {
        try await webCommander.send(.disconnect, payload: [:], generation: generation)
    }

    // MARK: - Commands for a device

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws {
        switch request {
        case let .item(uri):
            try await playbackAPI.play(uri: uri, deviceID: deviceID)
        case let .context(uri):
            try await playbackAPI.play(contextURI: uri, deviceID: deviceID)
        case let .items(uris, startURI?):
            try await playbackAPI.play(uris: uris, offsetURI: startURI, deviceID: deviceID)
        case let .items(uris, nil):
            try await playbackAPI.play(uris: uris, deviceID: deviceID)
        }
    }

    func pause(deviceID: String) async throws {
        try await playbackAPI.pause(deviceID: deviceID)
    }

    func resume(deviceID: String) async throws {
        try await playbackAPI.resume(deviceID: deviceID)
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        try await playbackAPI.seek(to: milliseconds, deviceID: deviceID)
    }

    func skipToNext(deviceID: String) async throws {
        try await playbackAPI.next(deviceID: deviceID)
    }

    func skipToPrevious(deviceID: String) async throws {
        try await playbackAPI.previous(deviceID: deviceID)
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        try await playbackAPI.setShuffle(enabled: enabled, deviceID: deviceID)
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        try await playbackAPI.setRepeat(mode: mode, deviceID: deviceID)
    }

    func enqueue(uri: String, deviceID: String) async throws {
        try await playbackAPI.addToQueue(uri: uri, deviceID: deviceID)
    }

    // MARK: - Commands for the in-app player

    func togglePlayPause() async throws {
        try await webCommander.send(.togglePlay, payload: [:])
    }

    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws {
        try await webCommander.send(.setVolume, payload: ["volume": volume], generation: generation)
    }

    func didStartLocalPlayback(uri: String) async throws {
        try await webCommander.send(.playURI, payload: ["uri": uri])
    }

    // MARK: - Reads

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
        try await playbackAPI.fetchPlayerSnapshot()
    }

    func fetchQueue() async throws -> MusicPlaybackQueue {
        try await playbackAPI.fetchQueue()
    }

    // MARK: - Spotify Connect

    func fetchAvailableDevices() async throws -> [MusicPlaybackDevice] {
        try await playbackAPI.fetchAvailableDevices()
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        try await playbackAPI.transferPlayback(to: deviceID, play: play)
    }
}
