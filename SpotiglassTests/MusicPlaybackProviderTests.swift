import XCTest
@testable import Spotiglass

/// The playback provider seam: the Spotify provider sends exactly the Web API and
/// SDK commands the session used to send itself, and a provider shaped like
/// MusicKit's `ApplicationMusicPlayer` (no device transfer, no pushed state, no
/// reloadable page) gets a working session.
@MainActor
final class MusicPlaybackProviderTests: XCTestCase {
    // MARK: - Spotify provider

    func testSpotifyProviderDeclaresItsSpotifyOnlyCapabilities() {
        let provider = SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI())

        XCTAssertTrue(provider.capabilities.contains(.pushesPlayerState))
        XCTAssertTrue(provider.capabilities.contains(.reloadablePlayer))
        XCTAssertNotNil(provider.deviceTransfer)
        let session = PlaybackSessionViewModel(provider: provider)
        XCTAssertTrue(session.supportsDeviceTransfer)
    }

    func testSpotifyProviderMapsPlayRequestsToTheSameWebAPICalls() async throws {
        let api = MockPlaybackAPI()
        let provider = SpotifyPlaybackProvider(playbackAPI: api)

        try await provider.play(.item(uri: "spotify:track:1"), deviceID: "device")
        try await provider.play(.context(uri: "spotify:playlist:p"), deviceID: "device")
        try await provider.play(.items(uris: ["spotify:track:1", "spotify:track:2"], startURI: "spotify:track:2"), deviceID: "device")
        XCTAssertEqual(api.lastPlayedURIQueue, ["spotify:track:1", "spotify:track:2"])
        XCTAssertEqual(api.lastPlayedOffsetURI, "spotify:track:2")
        try await provider.play(.items(uris: ["spotify:track:3"], startURI: nil), deviceID: "device")
        XCTAssertEqual(api.lastPlayedURIQueue, ["spotify:track:3"])
        XCTAssertNil(api.lastPlayedOffsetURI)

        XCTAssertEqual(api.actions.count, 4)
        XCTAssertTrue(api.actions[0].contains("spotify:track:1"))
        XCTAssertTrue(api.actions[1].contains("spotify:playlist:p"))
    }

    func testSpotifyProviderRoutesInAppPlayerCommandsToTheSDKPage() async throws {
        let api = MockPlaybackAPI()
        let commander = MockWebPlaybackCommander()
        let provider = SpotifyPlaybackProvider(playbackAPI: api, webCommander: commander)
        let generation = PlaybackHostGeneration.initial.advanced()

        provider.loadPlayer(generation: generation)
        try await provider.connectPlayer(generation: generation)
        try await provider.togglePlayPause()
        try await provider.setVolume(0.25, generation: generation)
        try await provider.didStartLocalPlayback(uri: "spotify:track:1")
        try await provider.disconnectPlayer(generation: generation)

        XCTAssertEqual(commander.loadedHostGenerations, [generation])
        XCTAssertEqual(
            commander.commands.map(\.command),
            [.connect, .togglePlay, .setVolume, .playURI, .disconnect]
        )
        XCTAssertEqual(commander.commands[2].payload["volume"] as? Double, 0.25)
        XCTAssertEqual(commander.commands[3].payload["uri"] as? String, "spotify:track:1")
        XCTAssertTrue(api.actions.isEmpty, "in-app player commands must not reach the Web API")
    }

    func testSpotifyProviderForwardsSDKEventsToTheSession() {
        let provider = SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI())
        let session = PlaybackSessionViewModel(provider: provider)
        session.setConnectionState(.connecting)

        provider.deliver(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "sdk-device"),
            hostGeneration: session.playbackHostGeneration
        ))

        XCTAssertEqual(session.deviceID, "sdk-device")
        XCTAssertEqual(session.connectionState, .ready(deviceID: "sdk-device"))
    }

    // MARK: - A provider without Spotify's capabilities

    func testSessionWithoutDeviceTransferNeverListsOrTransfersDevices() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setConnectionState(.ready(deviceID: "local"))

        XCTAssertFalse(session.supportsDeviceTransfer)
        await session.refreshConnectDevices(force: true)
        XCTAssertTrue(session.connectDevices.isEmpty)

        await session.play(uri: "music:song:1")

        XCTAssertEqual(provider.commands, ["play item music:song:1 on local"])
        XCTAssertTrue(session.hasTransferredPlaybackToCurrentDevice)
    }

    func testTogglePlayPauseUsesExplicitCommandsWhenStateIsOnlyRead() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        XCTAssertFalse(session.isRemotePlaybackActive)
        XCTAssertTrue(session.isPlayerStateRead)
        await session.togglePlayPause()

        XCTAssertEqual(provider.commands.first, "pause local")
        XCTAssertFalse(provider.commands.contains("togglePlayPause"))
        guard case .paused = session.connectionState else {
            return XCTFail("Expected an optimistic paused state, got \(session.connectionState)")
        }
    }

    /// MusicKit's player still reports "playing" for a moment after it was
    /// stopped. Those reads must not undo the optimistic pause; the first read
    /// after the settle window is applied.
    func testStalePlayingReadAfterPauseIsIgnoredUntilTheSettleWindowEnds() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        provider.state = Self.snapshot(isPlaying: true, progress: 11_000)
        await session.togglePlayPause()
        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0)

        var staleReads = 0
        while session.localMutationSettleTicksRemaining > 0, staleReads < 10 {
            await session.syncTransportFromSpotify()
            staleReads += 1
            guard case .paused = session.connectionState else {
                return XCTFail("A stale read flipped the paused state back to \(session.connectionState)")
            }
        }
        XCTAssertGreaterThan(provider.stateReadCount, 0)

        provider.state = Self.snapshot(isPlaying: false, progress: 11_500)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.connectionState, .paused(Self.song(position: 11_500)))

        provider.state = Self.snapshot(isPlaying: true, progress: 12_000)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.connectionState, .playing(Self.song(position: 12_000)))
    }

    func testRecoveryWithoutAReloadablePlayerOnlyRetriesConnect() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(
            provider: provider,
            playbackHostRecoveryConnectTimeout: .milliseconds(30)
        )
        session.setConnectionState(.error(PlaybackSessionViewModel.playbackDeviceNotReadyError()))

        await session.attemptPlaybackHostRecovery(cause: .notReady)

        XCTAssertEqual(provider.commands, ["connect"])
        XCTAssertEqual(session.playbackHostReuseSoftResetAttemptCount, 0)
        XCTAssertEqual(session.playbackHostReloadAttemptCount, 0)
        XCTAssertEqual(session.playbackHostRecoveryFailureCount, 1)
    }

    func testQueueReadsAndEnqueuesThroughTheProvider() async {
        let provider = ReadOnlyStatePlaybackProvider()
        provider.queue = MusicPlaybackQueue(queue: [.track(Self.track(uri: "music:song:2", name: "Next"))])
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 0)))
        let queue = QueueViewModel(provider: provider, playbackSession: session)

        await queue.requestQueueRefresh(trigger: .manual, allowsHiddenPanel: true)
        XCTAssertEqual(queue.upcomingItems.map(\.uri), ["music:song:2"])

        await queue.addToQueue(uri: "music:song:3")
        XCTAssertTrue(provider.commands.contains("enqueue music:song:3 on local"))
    }

    // MARK: - Fixtures

    private static func track(uri: String, name: String = "Song") -> MusicTrack {
        MusicTrack(
            id: uri,
            name: name,
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: uri
        )
    }

    private static func song(position: Int) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Song",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: position,
            uri: "music:song:1"
        )
    }

    private static func snapshot(isPlaying: Bool, progress: Int) -> MusicPlaybackSnapshot {
        MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: isPlaying,
            item: .track(track(uri: "music:song:1")),
            progressMilliseconds: progress
        )
    }
}

/// Shaped like MusicKit's `ApplicationMusicPlayer`: one local player, state is
/// read rather than pushed, no device transfer, nothing to reload.
@MainActor
final class ReadOnlyStatePlaybackProvider: MusicPlaybackProvider {
    let capabilities: MusicPlaybackCapabilities = []
    var eventHandler: ((MusicPlaybackEventEnvelope) -> Void)?
    var state: MusicPlaybackSnapshot?
    var queue = MusicPlaybackQueue(queue: [])
    private(set) var commands: [String] = []
    private(set) var stateReadCount = 0

    func loadPlayer(generation: PlaybackHostGeneration) { commands.append("loadPlayer") }
    func connectPlayer(generation: PlaybackHostGeneration) async throws { commands.append("connect") }
    func disconnectPlayer(generation: PlaybackHostGeneration) async throws { commands.append("disconnect") }

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws {
        switch request {
        case let .item(uri): commands.append("play item \(uri) on \(deviceID)")
        case let .context(uri): commands.append("play context \(uri) on \(deviceID)")
        case let .items(uris, startURI): commands.append("play \(uris.count) items from \(startURI ?? "start") on \(deviceID)")
        }
    }

    func pause(deviceID: String) async throws { commands.append("pause \(deviceID)") }
    func resume(deviceID: String) async throws { commands.append("resume \(deviceID)") }
    func seek(to milliseconds: Int, deviceID: String) async throws { commands.append("seek \(milliseconds) on \(deviceID)") }
    func skipToNext(deviceID: String) async throws { commands.append("next \(deviceID)") }
    func skipToPrevious(deviceID: String) async throws { commands.append("previous \(deviceID)") }
    func setShuffle(enabled: Bool, deviceID: String) async throws { commands.append("shuffle \(enabled) on \(deviceID)") }
    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws { commands.append("repeat \(mode) on \(deviceID)") }
    func enqueue(uri: String, deviceID: String) async throws { commands.append("enqueue \(uri) on \(deviceID)") }
    func togglePlayPause() async throws { commands.append("togglePlayPause") }
    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws { commands.append("volume \(volume)") }

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
        stateReadCount += 1
        return state
    }

    func fetchQueue() async throws -> MusicPlaybackQueue { queue }
}
