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

    /// A player with one constant id reports that same id after a reconnect.
    /// The Spotify page's "superseded device" fence must not drop it, or the
    /// session sits on connecting until the connect timeout.
    func testPlayerWithAConstantIDReconnectsAfterAnError() {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.setConnectionState(.connecting)
        provider.eventHandler?(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "local"),
            hostGeneration: session.playbackHostGeneration
        ))
        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))

        session.setConnectionState(.error(PlaybackSessionViewModel.playbackDeviceNotReadyError()))
        session.start()
        XCTAssertEqual(session.connectionState, .connecting)
        provider.eventHandler?(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "local"),
            hostGeneration: session.playbackHostGeneration
        ))

        XCTAssertEqual(session.deviceID, "local")
        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))
    }

    /// Same, when the player first reported not-ready (which marks its id as
    /// superseded for the Spotify page) and the user then reconnects.
    func testPlayerWithAConstantIDReconnectsAfterNotReady() {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.setConnectionState(.connecting)
        let ready = { provider.eventHandler?(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "local"),
            hostGeneration: session.playbackHostGeneration
        )) }
        ready()
        provider.eventHandler?(MusicPlaybackEventEnvelope(
            event: .notReady(deviceID: "local"),
            hostGeneration: session.playbackHostGeneration
        ))
        session.setConnectionState(.error(PlaybackSessionViewModel.playbackDeviceNotReadyError()))

        session.start()
        ready()

        XCTAssertEqual(session.deviceID, "local")
        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))
    }

    /// The Spotify page registers a new device per load, so a late `ready` for
    /// the old device after a reload is still ignored.
    func testSpotifyStillIgnoresTheOldDeviceAfterAReload() {
        let provider = SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI())
        let session = PlaybackSessionViewModel(provider: provider)
        session.setConnectionState(.connecting)
        provider.deliver(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "old-sdk"),
            hostGeneration: session.playbackHostGeneration
        ))
        session.setConnectionState(.error(PlaybackSessionViewModel.playbackDeviceNotReadyError()))
        session.start()

        provider.deliver(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "old-sdk"),
            hostGeneration: session.playbackHostGeneration
        ))

        XCTAssertNil(session.deviceID)
        XCTAssertEqual(session.connectionState, .connecting)
    }

    /// Reads are the only state source, so a track that advances while the app
    /// is in the background must still be read.
    func testPollingKeepsRunningInTheBackgroundOnlyWhenStateIsRead() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))
        session.isAppActive = false

        XCTAssertTrue(session.shouldRunTransportPolling())
        provider.state = MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: true,
            item: .track(Self.track(uri: "music:song:2", name: "Next")),
            progressMilliseconds: 1_000
        )
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.currentNowPlayingURI, "music:song:2")

        let spotify = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()))
        spotify.deviceID = "sdk-device"
        spotify.setConnectionState(.playing(Self.song(position: 10_000)))
        spotify.isAppActive = false
        XCTAssertFalse(spotify.shouldRunTransportPolling(), "Spotify's SDK pushes state; background polling stays off")
    }

    /// Starting a track from `.ready`: the first read that shows it playing is
    /// applied right away, and the poll loop is restarted at the settle cadence
    /// instead of finishing the long sleep it picked while `.ready`.
    func testPlayFromReadyAppliesTheFirstReadThatConfirmsIt() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.isAppActive = true
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.ready(deviceID: "local"))
        let pollTaskWhileReady = session.transportPollTask

        await session.play(uri: "music:song:1")

        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0)
        XCTAssertNotNil(session.transportPollTask)
        XCTAssertFalse(session.transportPollTask == pollTaskWhileReady, "the poll loop must restart after the command")
        XCTAssertEqual(session.currentTransportPollDelay(), .seconds(1))

        provider.state = Self.snapshot(isPlaying: true, progress: 500)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.connectionState, .playing(Self.song(position: 500)))
    }

    /// Play B while A plays, then pause before B is confirmed: a stale "B is
    /// playing" read must not undo the pause, and the read that shows B paused
    /// is applied inside the settle window.
    func testPauseDuringAPendingPlayKeepsItsSettleProtection() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        await session.play(uri: "music:song:2")
        await session.togglePlayPause()
        XCTAssertEqual(provider.commands.last, "pause local")
        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0)

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: true, progress: 300)
        await session.syncTransportFromSpotify()
        guard case .paused = session.connectionState else {
            return XCTFail("A stale playing read undid the pause: \(session.connectionState)")
        }

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: false, progress: 400)
        await session.syncTransportFromSpotify()
        guard case let .paused(nowPlaying) = session.connectionState else {
            return XCTFail("Expected paused, got \(session.connectionState)")
        }
        XCTAssertEqual(nowPlaying?.uri, "music:song:2")
    }

    /// Skip while paused: the read that shows the next item, still paused, is
    /// the confirmation and is applied right away.
    func testSkipWhilePausedAppliesTheConfirmingReadInsideTheSettleWindow() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.paused(Self.song(position: 10_000)))

        await session.next()
        XCTAssertEqual(provider.commands.last, "next local")
        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0)

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: false, progress: 0)
        await session.syncTransportFromSpotify()

        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0, "applied inside the settle window")
        guard case let .paused(nowPlaying) = session.connectionState else {
            return XCTFail("Expected paused, got \(session.connectionState)")
        }
        XCTAssertEqual(nowPlaying?.uri, "music:song:2")
    }

    /// Skip past the last item: the player has nothing left and reads empty.
    /// That read is applied right away, not after the settle window and a long
    /// no-snapshot poll.
    /// Pause, then skip right away: the skip doesn't touch play / pause, so the
    /// pause's protection stays and a stale "B is playing" read can't undo it.
    func testSkipRightAfterAPauseKeepsThePauseProtection() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        await session.togglePlayPause()
        await session.next()
        XCTAssertEqual(provider.commands, ["pause local", "next local"])

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: true, progress: 0)
        await session.syncTransportFromSpotify()
        guard case .paused = session.connectionState else {
            return XCTFail("A stale playing read undid the pause: \(session.connectionState)")
        }

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: false, progress: 0)
        await session.syncTransportFromSpotify()
        guard case let .paused(nowPlaying) = session.connectionState else {
            return XCTFail("Expected paused, got \(session.connectionState)")
        }
        XCTAssertEqual(nowPlaying?.uri, "music:song:2")
    }

    /// The same the other way: resume, then skip, then a stale "paused" read.
    /// Start a new item and press Space before a read confirms it: the screen
    /// can still show `.ready` (or the old paused item), but the player was
    /// asked to play, so the toggle pauses.
    /// A new item that takes longer than the settle window to start: Space
    /// still pauses while its play is pending, and the expectation ends with
    /// the pending play instead of sticking around.
    func testSlowStartKeepsThePlayExpectationUntilThePendingPlayEnds() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.ready(deviceID: "local"))

        await session.play(uri: "music:song:2")
        provider.state = nil
        while session.localMutationSettleTicksRemaining > 0 {
            await session.syncTransportFromSpotify()
        }
        XCTAssertNotNil(session.pendingPlayTransition)
        XCTAssertEqual(session.localCommandExpectsPlaying, true)

        session.clearPendingPlay()
        XCTAssertNil(session.localCommandExpectsPlaying, "no stale expectation once the play stopped waiting")

        let slow = PlaybackSessionViewModel(provider: provider)
        slow.deviceID = "local"
        slow.setActivePlaybackDeviceID("local")
        slow.setConnectionState(.ready(deviceID: "local"))
        await slow.play(uri: "music:song:3")
        while slow.localMutationSettleTicksRemaining > 0 {
            await slow.syncTransportFromSpotify()
        }
        await slow.togglePlayPause()
        XCTAssertEqual(provider.commands.last, "pause local")
    }

    func testToggleRightAfterStartingANewItemPauses() async {
        for start in [PlaybackConnectionState.ready(deviceID: "local"), .paused(Self.song(position: 10_000))] {
            let provider = ReadOnlyStatePlaybackProvider()
            let session = PlaybackSessionViewModel(provider: provider)
            session.deviceID = "local"
            session.setActivePlaybackDeviceID("local")
            session.setConnectionState(start)

            await session.play(uri: "music:song:2")
            await session.togglePlayPause()

            XCTAssertEqual(provider.commands.last, "pause local", "from \(start)")
            guard case .paused = session.connectionState else {
                return XCTFail("Expected an optimistic pause from \(start), got \(session.connectionState)")
            }
        }
    }

    /// Start a list at B and press Next before B is confirmed: the player moves
    /// on to C, and the read of C is applied instead of being fenced off as
    /// "not B" until the pending play times out.
    func testSkipDuringAPendingPlayAppliesTheNextItem() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        await session.playFromPlaylist(
            clickedURI: "music:song:2",
            playableURIs: ["music:song:2", "music:song:3"]
        )
        XCTAssertNotNil(session.pendingPlayTransition)
        await session.next()
        XCTAssertEqual(provider.commands.last, "next local")

        provider.state = Self.snapshot(uri: "music:song:3", isPlaying: true, progress: 0)
        await session.syncTransportFromSpotify()

        XCTAssertEqual(session.currentNowPlayingURI, "music:song:3")
        guard case .playing = session.connectionState else {
            return XCTFail("Expected playing, got \(session.connectionState)")
        }
    }

    /// Same, skipping past the end: the empty read isn't held back by the
    /// pending play the skip replaced.
    /// Resume on the last item, Next within a second, the player runs out and
    /// reads empty. The bar shows ready; the next Space resumes (there is
    /// nothing to pause) instead of following the finished resume.
    func testToggleAfterTheQueueRanOutFollowsTheScreen() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.paused(Self.song(position: 190_000)))

        await session.togglePlayPause()
        await session.next()
        provider.state = nil
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))

        await session.togglePlayPause()
        XCTAssertEqual(provider.commands, ["resume local", "next local", "resume local"])
    }

    func testSkipPastTheEndDuringAPendingPlayGoesBackToReady() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        await session.play(uri: "music:song:2")
        await session.next()
        provider.state = nil
        await session.syncTransportFromSpotify()

        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))
    }

    func testSkipRightAfterAResumeKeepsTheResumeProtection() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.paused(Self.song(position: 10_000)))

        await session.togglePlayPause()
        await session.next()
        XCTAssertEqual(provider.commands, ["resume local", "next local"])

        provider.state = Self.snapshot(uri: "music:song:2", isPlaying: false, progress: 0)
        await session.syncTransportFromSpotify()
        guard case .playing = session.connectionState else {
            return XCTFail("A stale paused read undid the resume: \(session.connectionState)")
        }
    }

    /// A command while the poll loop is mid-read keeps that loop: it picks the
    /// settle cadence itself after the read, and cancelling it would drop the
    /// read the command queued. A loop that is only sleeping is restarted.
    func testCommandDoesNotCancelAPollLoopThatIsMidRead() {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.isAppActive = true
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))
        let readingLoop = session.transportPollTask
        XCTAssertNotNil(readingLoop)

        session.transportPollReadingSerial = session.transportPollLoopSerial
        session.noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
        XCTAssertTrue(session.transportPollTask == readingLoop, "a loop mid-read must not be cancelled")
        XCTAssertEqual(session.currentTransportPollDelay(), .seconds(1))

        session.transportPollReadingSerial = nil
        session.noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
        XCTAssertFalse(session.transportPollTask == readingLoop, "a sleeping loop is restarted")
    }

    func testEmptyReadAfterSkippingPastTheEndIsAppliedRightAway() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 190_000)))

        await session.next()
        XCTAssertGreaterThan(session.localMutationSettleTicksRemaining, 0)
        provider.state = nil
        await session.syncTransportFromSpotify()

        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))
    }

    /// While a play command waits for such a player to start, reads stay at
    /// the settle cadence even after the settle window, instead of the 20 s
    /// used when no player state is known.
    func testPendingPlayKeepsReadingEverySecond() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.ready(deviceID: "local"))

        await session.play(uri: "music:song:1")
        provider.state = nil
        while session.localMutationSettleTicksRemaining > 0 {
            await session.syncTransportFromSpotify()
        }

        XCTAssertNotNil(session.pendingPlayTransition)
        XCTAssertEqual(session.currentTransportPollDelay(), .seconds(1))
    }

    /// An empty read means nothing plays on the player any more. Without pushed
    /// state nothing else corrects the old item, so the session goes back to ready.
    func testEmptyReadClearsAStalePlayingItem() async {
        let provider = ReadOnlyStatePlaybackProvider()
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song(position: 10_000)))

        provider.state = nil
        await session.syncTransportFromSpotify()

        XCTAssertEqual(session.connectionState, .ready(deviceID: "local"))
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

    private static func snapshot(
        uri: String = "music:song:1",
        isPlaying: Bool,
        progress: Int
    ) -> MusicPlaybackSnapshot {
        MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: isPlaying,
            item: .track(track(uri: uri)),
            progressMilliseconds: progress
        )
    }
}

/// Shaped like MusicKit's `ApplicationMusicPlayer`: one local player, state is
/// read rather than pushed, no device transfer, nothing to reload.
@MainActor
final class ReadOnlyStatePlaybackProvider: MusicPlaybackProvider {
    let service: MusicService = .appleMusic
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
