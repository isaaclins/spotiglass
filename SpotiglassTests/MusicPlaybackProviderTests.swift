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
        try await provider.togglePlayPause(commandID: nil)
        try await provider.setInAppPlayerPlaying(false, commandID: 7)
        try await provider.setInAppPlayerPlaying(true, commandID: nil)
        try await provider.setVolume(0.25, generation: generation)
        try await provider.didStartLocalPlayback(uri: "spotify:track:1")
        try await provider.disconnectPlayer(generation: generation)

        XCTAssertEqual(commander.loadedHostGenerations, [generation])
        XCTAssertEqual(
            commander.commands.map(\.command),
            [.connect, .togglePlay, .pause, .resume, .setVolume, .playURI, .disconnect]
        )
        XCTAssertEqual((commander.commands[2].payload["id"] as? NSNumber)?.uint64Value, 7, "the press's id goes to the page")
        XCTAssertEqual(commander.commands[4].payload["volume"] as? Double, 0.25)
        XCTAssertEqual(commander.commands[5].payload["uri"] as? String, "spotify:track:1")
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
        // The player still reports the song playing when it is read right after the pause.
        provider.state = Self.snapshot(isPlaying: true, progress: 10_000)

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
        // Read right after the pause, the player still reports A playing.
        provider.state = Self.snapshot(isPlaying: true, progress: 10_000)

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
        // Read right after the resume, the player still reports A paused.
        provider.state = Self.snapshot(isPlaying: false, progress: 10_000)

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

    /// While true, pause and resume wait until ``releaseCommands()``, like a player that takes
    /// its time to answer.
    var holdsCommands = false
    /// What pause and resume throw once they go through (the player refusing them).
    var refusal: Error?
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    var waitingCommandCount: Int { commandWaiters.count }

    func releaseCommands() {
        let waiting = commandWaiters
        commandWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func answer() async throws {
        if holdsCommands {
            await withCheckedContinuation { commandWaiters.append($0) }
        }
        if let refusal { throw refusal }
    }

    func pause(deviceID: String) async throws {
        commands.append("pause \(deviceID)")
        try await answer()
    }

    func resume(deviceID: String) async throws {
        commands.append("resume \(deviceID)")
        try await answer()
    }
    func seek(to milliseconds: Int, deviceID: String) async throws { commands.append("seek \(milliseconds) on \(deviceID)") }
    func skipToNext(deviceID: String) async throws { commands.append("next \(deviceID)") }
    func skipToPrevious(deviceID: String) async throws { commands.append("previous \(deviceID)") }
    func setShuffle(enabled: Bool, deviceID: String) async throws { commands.append("shuffle \(enabled) on \(deviceID)") }
    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws { commands.append("repeat \(mode) on \(deviceID)") }
    func enqueue(uri: String, deviceID: String) async throws { commands.append("enqueue \(uri) on \(deviceID)") }
    func togglePlayPause(commandID: UInt64?) async throws { commands.append("togglePlayPause") }
    func setInAppPlayerPlaying(_ playing: Bool, commandID: UInt64?) async throws { commands.append(playing ? "inAppPlay" : "inAppPause") }
    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws { commands.append("volume \(volume)") }

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
        stateReadCount += 1
        return state
    }

    func fetchQueue() async throws -> MusicPlaybackQueue { queue }
}

/// Play / pause shows the moment it is pressed, with every player (#437). The report: the music
/// stopped or started at once, but the button, the playing row and the sidebar only caught up
/// about 5 seconds later, and a second press in that time flipped it back. These replay a player
/// that answers slowly and reports its own state late.
@MainActor
final class PlayPauseFollowsThePressTests: XCTestCase {
    private static let song = PlaybackNowPlaying(
        name: "Piranguera",
        artists: ["Artist"],
        albumName: nil,
        albumID: nil,
        albumArtURL: nil,
        durationMilliseconds: 200_000,
        positionMilliseconds: 10_000,
        uri: "music:song:1"
    )

    private static func snapshot(isPlaying: Bool, device: MusicPlaybackDevice? = nil) -> MusicPlaybackSnapshot {
        MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: device,
            isPlaying: isPlaying,
            item: .track(PlaylistBrowsingTestFixtures.fallbackTrack(id: "1", name: "Piranguera", artistId: "a")),
            progressMilliseconds: 10_000
        )
    }

    private static func isPlaying(_ session: PlaybackSessionViewModel) -> Bool {
        if case .playing = session.connectionState { return true }
        return false
    }

    private static func isPaused(_ session: PlaybackSessionViewModel) -> Bool {
        if case .paused = session.connectionState { return true }
        return false
    }

    /// Lets the tasks that are ready run, until `condition` holds.
    /// Ends the wait for Spotify's page to answer the press in flight, as if it never answered.
    /// The session's clock is stepped, so a busy machine can't fire it late (#510).
    private static func endAckWait(_ session: PlaybackSessionViewModel, on clock: ManualPlaybackClock) async {
        let wait = session.inAppCommandAckTimeoutTask
        XCTAssertNotNil(wait, "no press waits for the page")
        clock.advance(by: session.inAppCommandAckTimeout)
        await wait?.value
    }

    /// Ends the wait for Spotify's page to report the last press.
    private static func endReportWait(
        _ wait: Task<Void, Never>?,
        of session: PlaybackSessionViewModel,
        on clock: ManualPlaybackClock
    ) async {
        clock.advance(by: session.pushedPlayStateExpectationTimeout)
        await wait?.value
    }

    private static func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<50 where !condition() { await Task.yield() }
    }

    /// Apple Music: a player whose state is read, and which reports "playing" a while after it
    /// was paused.
    private func playingReadPlayer(
        clock: any PlaybackClock = ContinuousClock()
    ) -> (ReadOnlyStatePlaybackProvider, PlaybackSessionViewModel) {
        let provider = ReadOnlyStatePlaybackProvider()
        provider.state = Self.snapshot(isPlaying: true)
        let session = PlaybackSessionViewModel(provider: provider, clock: clock)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song))
        return (provider, session)
    }

    func testPauseShowsWhileThePlayerIsStillAnswering() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true

        let press = Task { await session.togglePlayPause() }
        await Self.settle { provider.waitingCommandCount == 1 }
        XCTAssertEqual(provider.commands, ["pause local"])
        XCTAssertTrue(Self.isPaused(session), "the controls waited for the player to answer the pause")

        provider.releaseCommands()
        await press.value
        // The player's own status arrives late: it still says playing.
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session), "a late status flipped the pause back")
        provider.state = Self.snapshot(isPlaying: false)
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session))
    }

    /// The bar, Space, the menu and the rows call this from the click itself: the new state is
    /// set before any task runs, so nothing queued on the main thread can hold it back.
    func testTheControlsFlipBeforeAnyTaskRuns() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true

        let send = session.requestTogglePlayPause()
        XCTAssertTrue(Self.isPaused(session))
        XCTAssertTrue(provider.commands.isEmpty, "the command follows the screen, not the other way round")

        await Self.settle { provider.waitingCommandCount == 1 }
        provider.releaseCommands()
        await send?.value
        XCTAssertEqual(provider.commands, ["pause local"])
    }

    func testTwoQuickPressesEndInTheLastOneWithoutFlickering() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true
        var shown: [Bool] = []
        let watch = session.connectionStatePublisher.dropFirst().sink { state in
            shown.append(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: state))
        }
        defer { watch.cancel() }

        let pause = Task { await session.togglePlayPause() }
        await Self.settle { provider.waitingCommandCount == 1 }
        let play = Task { await session.togglePlayPause() }
        await Self.settle()
        XCTAssertTrue(Self.isPlaying(session), "the second press shows at once too")

        provider.releaseCommands()
        await pause.value
        await Self.settle { provider.waitingCommandCount == 1 }
        provider.releaseCommands()
        await play.value
        XCTAssertEqual(provider.commands, ["pause local", "resume local"], "in the order pressed")

        // The player reports the pause late, then the resume.
        provider.state = Self.snapshot(isPlaying: false)
        await session.syncTransportFromSpotify()
        provider.state = Self.snapshot(isPlaying: true)
        await session.syncTransportFromSpotify()
        await session.syncTransportFromSpotify()

        XCTAssertTrue(Self.isPlaying(session))
        // A read may replace the item's details; what counts is each change between playing and paused.
        let flips = shown.reduce(into: [Bool]()) { flips, playing in
            if flips.last != playing { flips.append(playing) }
        }
        XCTAssertEqual(flips, [false, true], "the state went back and forth while the player caught up")
    }

    func testARefusedPauseGoesBackAndSaysWhy() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true
        provider.refusal = MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "refused")

        let press = Task { await session.togglePlayPause() }
        await Self.settle { provider.waitingCommandCount == 1 }
        XCTAssertTrue(Self.isPaused(session))
        provider.releaseCommands()
        await press.value

        XCTAssertEqual(session.connectionState, .playing(Self.song), "the controls kept showing a pause that didn't happen")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.pause"))
        XCTAssertEqual(session.refusedPlayPause?.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))
        XCTAssertNil(session.localCommandExpectsPlaying, "the next read must be believed again")

        provider.refusal = nil
        provider.holdsCommands = false
        await session.togglePlayPause()
        XCTAssertNil(session.refusedPlayPause, "a new press clears the old refusal")
        XCTAssertTrue(Self.isPaused(session))
    }

    func testARefusalOnlyYouCanFixStillShowsTheError() async {
        let (provider, session) = playingReadPlayer()
        provider.refusal = MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: "off")

        await session.togglePlayPause()

        guard case let .error(error) = session.connectionState else {
            return XCTFail("Expected the permission error, got \(session.connectionState)")
        }
        XCTAssertEqual(error.title, SpotiglassL10n.string("error.playback.appleMusic.permission.title"))
        XCTAssertNil(session.refusedPlayPause)
    }

    // MARK: - Spotify

    /// Spotify in the app: its page reports the new state only after the toggle, sometimes with
    /// a report from before it first.
    private func playingSpotify(
        clock: any PlaybackClock = ContinuousClock()
    ) -> (MockWebPlaybackCommander, PlaybackSessionViewModel) {
        let commander = MockWebPlaybackCommander()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            clock: clock
        )
        session.handle(.ready(deviceID: "sdk-device"))
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        return (commander, session)
    }

    private static func playPauseCommands(_ commander: MockWebPlaybackCommander) -> [PlaybackBridgeCommand] {
        commander.commands.map(\.command).filter { [.togglePlay, .pause, .resume].contains($0) }
    }

    func testSpotifyShowsThePressBeforeItsPageReportsIt() async {
        let (commander, session) = playingSpotify()

        await session.togglePlayPause()
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause], "the press sends the state it asked for")
        XCTAssertTrue(Self.isPaused(session), "the controls waited for Spotify's page")

        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        XCTAssertTrue(Self.isPaused(session), "a report from before the press flipped it back")
        session.handle(.stateChanged(Self.song, isPaused: true, nextTracks: []))
        XCTAssertTrue(Self.isPaused(session))

        // Once the page agreed, its reports count again (paused from the phone, played again).
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        XCTAssertTrue(Self.isPlaying(session))
    }

    func testSpotifyTwoQuickPressesEndInTheLastOne() async {
        let (commander, session) = playingSpotify()

        await session.togglePlayPause()
        session.handle(.playerCommandFinished(command: "pause"))
        await session.togglePlayPause()
        // Pause then resume, not two toggles: the page answers before Spotify's player has
        // applied the first, so a second toggle could flip the old state and stay paused.
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume], "the second press was dropped")
        XCTAssertTrue(Self.isPlaying(session))

        // The page reports the pause late, then the play.
        session.handle(.stateChanged(Self.song, isPaused: true, nextTracks: []))
        XCTAssertTrue(Self.isPlaying(session), "the late pause flickered on screen")
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        XCTAssertTrue(Self.isPlaying(session))
    }

    /// Spotify on another device (a phone): its state comes from Web API reads, which can still
    /// show the old state right after the pause.
    func testSpotifyOnAnotherDeviceIgnoresAReadFromBeforeThePause() async {
        let phone = MusicPlaybackDevice(
            deviceID: "phone-device",
            isActive: true,
            isRestricted: false,
            name: "Phone",
            type: "smartphone"
        )
        let api = MockPlaybackAPI()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        session.deviceID = "local-device"
        session.setConnectionState(.ready(deviceID: "local-device"))
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPlaying(session))

        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        await session.togglePlayPause()
        await Self.settle()
        XCTAssertTrue(api.actions.contains("pause:phone-device"))
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session), "a read from before the pause flipped it back")

        api.snapshotResponses = [Self.snapshot(isPlaying: false, device: phone)]
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session))
    }

    /// Spotify refusing a pause (HTTP 503): the bar says so in a sentence, not with the raw
    /// error Spotify's display error keeps for diagnostics.
    func testASpotifyRefusalSaysWhyInASentence() async {
        let phone = MusicPlaybackDevice(deviceID: "phone-device", isActive: true, isRestricted: false, name: "Phone", type: "smartphone")
        let api = MockPlaybackAPI()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        session.deviceID = "local-device"
        session.setConnectionState(.ready(deviceID: "local-device"))
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPlaying(session))

        api.pauseError = SpotifyAPIError.server(statusCode: 503, message: nil, details: nil)
        await session.togglePlayPause()

        XCTAssertTrue(Self.isPlaying(session), "the refused pause went back")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.pause"))
        XCTAssertEqual(session.refusedPlayPause?.message, SpotiglassL10n.string("error.playback.spotify.failed"))
    }

    /// Spotify on a phone: a read sent before a quick pause, play comes back after them saying
    /// "playing". That agrees with the play only by luck, so the reads that follow (the Web API
    /// catching up with the pause) still mustn't flip the controls to paused.
    func testSpotifyOnAnotherDeviceAReadSentBeforeThePressesDoesntEndTheWait() async {
        let phone = MusicPlaybackDevice(deviceID: "phone-device", isActive: true, isRestricted: false, name: "Phone", type: "smartphone")
        let api = MockPlaybackAPI()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        session.deviceID = "local-device"
        session.setConnectionState(.ready(deviceID: "local-device"))
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPlaying(session))

        let gate = ReadGate()
        api.onFetchPlayerSnapshot = { await gate.hold() }
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        let earlyRead = Task { await session.syncTransportFromSpotify() }
        await Self.settle { gate.isHolding }
        api.onFetchPlayerSnapshot = nil

        await session.requestTogglePlayPause()?.value
        await session.requestTogglePlayPause()?.value
        XCTAssertEqual(api.actions.filter { $0.hasPrefix("pause:") || $0.hasPrefix("resume:") }, ["pause:phone-device", "resume:phone-device"])
        // The early read comes back saying "playing"; every read after it shows the Web API
        // catching up with the pause.
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
            + Array(repeating: Self.snapshot(isPlaying: false, device: phone), count: 8)
        gate.release()
        await earlyRead.value
        XCTAssertTrue(Self.isPlaying(session))

        for read in 1...4 {
            await session.syncTransportFromSpotify()
            XCTAssertTrue(Self.isPlaying(session), "late read \(read) of the pause flipped the play back")
        }
        api.snapshotResponses = [Self.snapshot(isPlaying: true, device: phone)]
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPlaying(session))
    }

    // MARK: - Late reports, refusals of more than one press

    /// Pause then play, and both refused (Spotify on a phone that's gone offline): the music
    /// never stopped, so the controls end playing, not on the first press's pause.
    func testTwoRefusedPressesGoBackToWhatThePlayerHas() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true
        provider.refusal = MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "offline")

        let pause = session.requestTogglePlayPause()
        await Self.settle { provider.waitingCommandCount == 1 }
        let play = session.requestTogglePlayPause()
        XCTAssertTrue(Self.isPlaying(session))

        provider.releaseCommands()
        await pause?.value
        await Self.settle { provider.waitingCommandCount == 1 }
        provider.releaseCommands()
        await play?.value

        XCTAssertEqual(provider.commands, ["pause local", "resume local"])
        XCTAssertEqual(session.connectionState, .playing(Self.song), "the controls ended on a pause that never happened")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.play"))
    }

    /// Pause accepted, play refused: the player has the pause, so the controls go back to it.
    func testARefusedSecondPressGoesBackToTheFirstOne() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true

        let pause = session.requestTogglePlayPause()
        await Self.settle { provider.waitingCommandCount == 1 }
        let play = session.requestTogglePlayPause()
        provider.releaseCommands()
        await pause?.value
        await Self.settle { provider.waitingCommandCount == 1 }
        provider.refusal = MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "busy")
        provider.releaseCommands()
        await play?.value

        XCTAssertTrue(Self.isPaused(session))
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.play"))
    }

    /// A service that keeps reporting the old state for several reads (Spotify's Web API right
    /// after a pause on a phone): none of them flips the pause back, however many there are.
    func testSeveralLateReadsDontUndoAPause() async {
        let (provider, session) = playingReadPlayer()

        await session.requestTogglePlayPause()?.value
        for read in 1...4 {
            await session.syncTransportFromSpotify()
            XCTAssertTrue(Self.isPaused(session), "late read \(read) flipped the pause back")
        }
        provider.state = Self.snapshot(isPlaying: false)
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session))
        XCTAssertNil(session.playPauseReadHoldUntil, "a read that agrees ends the wait")
    }

    /// The wait for a slow service has an end: after it, a read that still disagrees is
    /// believed (the music was started again elsewhere).
    func testLateReadsAreBelievedAfterTheWait() async {
        let clock = ManualPlaybackClock()
        let provider = ReadOnlyStatePlaybackProvider()
        provider.state = Self.snapshot(isPlaying: true)
        let session = PlaybackSessionViewModel(provider: provider, clock: clock)
        session.deviceID = "local"
        session.setActivePlaybackDeviceID("local")
        session.setConnectionState(.playing(Self.song))

        await session.requestTogglePlayPause()?.value
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPaused(session))

        clock.advance(by: PlaybackSessionViewModel.playPauseReadHoldDuration + .milliseconds(1))
        for _ in 1...3 { await session.syncTransportFromSpotify() }
        XCTAssertTrue(Self.isPlaying(session), "the controls never caught up with the player")
    }

    /// Spotify in the app, pause then play: its page may first send a report from before both
    /// presses, then the pause, then the play. Only the last one may show: the pause in between
    /// would flicker.
    func testSpotifyReportsForEarlierPressesDontFlicker() {
        let (_, session) = playingSpotify()
        var shown: [Bool] = []
        let watch = session.connectionStatePublisher.dropFirst().sink { state in
            shown.append(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: state))
        }
        defer { watch.cancel() }

        session.requestTogglePlayPause()
        session.requestTogglePlayPause()
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        session.handle(.stateChanged(Self.song, isPaused: true, nextTracks: []))
        XCTAssertTrue(Self.isPlaying(session), "the report for the first press flickered on screen")
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))

        let flips = shown.reduce(into: [Bool]()) { flips, playing in
            if flips.last != playing { flips.append(playing) }
        }
        XCTAssertEqual(flips, [false, true])
        // The page has reported both presses: its reports count again.
        session.handle(.stateChanged(Self.song, isPaused: true, nextTracks: []))
        XCTAssertTrue(Self.isPaused(session))
    }

    /// Spotify's page refusing the pause (its promise rejected): the controls go back to what
    /// the page last reported and the bar says so, instead of an error over the whole bar.
    func testSpotifyPageRefusingAPauseGoesBack() async {
        let (_, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        XCTAssertTrue(Self.isPaused(session))
        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: offline"))

        XCTAssertTrue(Self.isPlaying(session), "the controls kept showing a pause that didn't happen")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.pause"))
        XCTAssertEqual(session.refusedPlayPause?.message, SpotiglassL10n.string("error.playback.spotify.failed"))
    }

    /// Pause then play, and the page refuses the pause: the play decides, so nothing on screen
    /// changes, the play goes out, and its report is shown (the page never reports the pause).
    func testSpotifyPageRefusingAnEarlierPressChangesNothing() async {
        let (commander, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        let play = session.requestTogglePlayPause()
        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: offline"))
        await play?.value

        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume])
        XCTAssertTrue(Self.isPlaying(session))
        XCTAssertNil(session.refusedPlayPause)
        // The next song starts: its report shows, instead of waiting for the refused pause's.
        let next = PlaybackNowPlaying(
            name: "Next", artists: ["Artist"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 180_000, positionMilliseconds: 0, uri: "spotify:track:next"
        )
        session.handle(.stateChanged(next, isPaused: false, nextTracks: []))
        XCTAssertEqual(session.currentNowPlaying?.name, "Next")
    }

    /// Pause, play, pause, and the page refuses the first pause while the others wait: that is
    /// not the last pause's refusal, which goes out and decides.
    func testSpotifyPageRefusingTheFirstOfTwoPausesIsNotTheLastOnes() async {
        let (commander, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        let play = session.requestTogglePlayPause()
        let pause = session.requestTogglePlayPause()
        XCTAssertTrue(Self.isPaused(session))
        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: offline"))
        await Self.settle { Self.playPauseCommands(commander).count == 2 }
        session.handle(.playerCommandFinished(command: "resume"))
        await play?.value
        await pause?.value

        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume, .pause])
        XCTAssertTrue(Self.isPaused(session), "the first pause's refusal undid the last pause")
        XCTAssertNil(session.refusedPlayPause)
    }

    /// Spotify's page runs a command after the script that starts it returns: a quick pause,
    /// play must not both run at once in its player, where the pause could land last.
    func testSpotifyPlayWaitsUntilThePageHasRunThePause() async {
        let (commander, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        let play = session.requestTogglePlayPause()
        await Self.settle()
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause], "the play went out while the page still ran the pause")

        session.handle(.playerCommandFinished(command: "pause"))
        await play?.value
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume])
    }

    /// A page that never answers doesn't hold the next press for ever.
    func testSpotifyPlayGoesOutWhenThePageNeverAnswers() async {
        let clock = ManualPlaybackClock()
        let (commander, session) = playingSpotify(clock: clock)
        session.inAppCommandAckTimeout = .milliseconds(20)

        await session.requestTogglePlayPause()?.value
        let play = session.requestTogglePlayPause()
        await Self.settle()
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause], "the play went out before the wait ended")
        await Self.endAckWait(session, on: clock)
        await play?.value
        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume])
    }

    /// The page answers a pause only after the 3 s wait, and it's a refusal: the controls still
    /// go back and the bar says so, instead of showing a pause that never happened.
    func testSpotifyPageRefusingAPauseLateStillGoesBack() async {
        let clock = ManualPlaybackClock()
        let (_, session) = playingSpotify(clock: clock)
        session.inAppCommandAckTimeout = .milliseconds(20)

        await session.requestTogglePlayPause()?.value
        await Self.endAckWait(session, on: clock)
        XCTAssertNil(session.inAppCommandInFlight, "the wait for the page ended")
        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: offline"))

        XCTAssertTrue(Self.isPlaying(session), "the late refusal was dropped and the pause stayed on screen")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.pause"))
    }

    /// Pause, then another song at once: the new song's report shows right away, not after the
    /// wait for the pause's report.
    func testSpotifyANewSongRightAfterAPauseShowsAtOnce() async {
        let (_, session) = playingSpotify()

        session.requestTogglePlayPause()
        XCTAssertTrue(Self.isPaused(session))
        await session.play(uri: "spotify:track:other")
        let other = PlaybackNowPlaying(
            name: "Other", artists: ["Artist"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 180_000, positionMilliseconds: 0, uri: "spotify:track:other"
        )
        session.handle(.stateChanged(other, isPaused: false, nextTracks: []))

        XCTAssertEqual(session.currentNowPlaying?.name, "Other")
        XCTAssertTrue(Self.isPlaying(session), "the new song waited for the pause's report")
    }

    /// A report held back while a press waited belongs to the page that sent it: after a
    /// reconnect starts a new page, it is never shown.
    func testSpotifyAHeldBackReportFromAReplacedPageIsDropped() async {
        let clock = ManualPlaybackClock()
        let (_, session) = playingSpotify(clock: clock)
        session.pushedPlayStateExpectationTimeout = .milliseconds(20)

        session.requestTogglePlayPause()
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        XCTAssertNotNil(session.heldBackPageReport)
        let wait = session.pushedPlayStateExpectationTask
        _ = session.beginPlaybackHostLifecycle()
        XCTAssertNil(session.heldBackPageReport)
        XCTAssertTrue(session.pushedPlayStateExpectations.isEmpty)

        let state = session.connectionState
        await Self.endReportWait(wait, of: session, on: clock)
        XCTAssertEqual(session.connectionState, state, "the old page's report was shown after the reconnect")
    }

    /// Pause, play, pause, and the page answers the first pause only after the wait: its late
    /// refusal carries that press's id, so it isn't taken for the last pause's (#437).
    func testSpotifyALateRefusalIsMatchedByItsPressNotItsName() async {
        let clock = ManualPlaybackClock()
        let (_, session) = playingSpotify(clock: clock)
        session.inAppCommandAckTimeout = .milliseconds(20)

        await session.requestTogglePlayPause()?.value
        let firstPause = session.playPauseRequestSerial
        await Self.endAckWait(session, on: clock)
        await session.requestTogglePlayPause()?.value
        session.handle(.playerCommandFinished(command: "resume", id: session.playPauseRequestSerial))
        await session.requestTogglePlayPause()?.value
        let lastPause = session.playPauseRequestSerial
        XCTAssertEqual(session.inAppCommandInFlight?.serial, lastPause)

        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: offline", id: firstPause))
        XCTAssertTrue(Self.isPaused(session), "the first pause's refusal undid the last pause")
        XCTAssertNil(session.refusedPlayPause)
        XCTAssertEqual(session.inAppCommandInFlight?.serial, lastPause, "the first pause's answer let the next press go early")
    }

    /// Play, pause while the page still runs the play, then another song: the pause waiting its
    /// turn never goes out, or it would stop the song chosen last.
    func testSpotifyAPressWaitingItsTurnDoesntReachASongChosenAfterIt() async {
        let (commander, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        let play = session.requestTogglePlayPause()
        await session.play(uri: "spotify:track:other")
        session.handle(.playerCommandFinished(command: "pause", id: session.playPauseRequestSerial - 1))
        await play?.value

        XCTAssertEqual(Self.playPauseCommands(commander), [.pause], "a press from before the new song reached it")
    }

    /// A pause stuck on the old player when it reconnects doesn't hold the first press on the
    /// new one: it goes out at once.
    func testAPressAfterAReconnectDoesntWaitForTheOldPlayer() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true

        let stuck = session.requestTogglePlayPause()
        await Self.settle { provider.waitingCommandCount == 1 }
        _ = session.beginPlaybackHostLifecycle()
        session.setConnectionState(.paused(Self.song))
        provider.holdsCommands = false
        let press = session.requestTogglePlayPause()
        await Self.settle { provider.commands.count == 2 }

        XCTAssertEqual(provider.commands, ["pause local", "resume local"], "the new press waited for the stuck one")
        provider.releaseCommands()
        await stuck?.value
        await press?.value
    }

    /// Apple Music, paused: play, and pause while the play is still starting (a stream that
    /// takes its time). The pause doesn't wait for ever, and if the play lands after it, the
    /// pause is sent again: the last press wins.
    func testAPauseDuringASlowPlayStillEndsPaused() async {
        let clock = ManualPlaybackClock()
        let (provider, session) = playingReadPlayer(clock: clock)
        session.setConnectionState(.paused(Self.song))
        provider.state = Self.snapshot(isPlaying: false)
        session.playPauseQueueWait = .milliseconds(20)
        provider.holdsCommands = true

        let play = session.requestTogglePlayPause()
        await Self.settle { provider.waitingCommandCount == 1 }
        provider.holdsCommands = false
        let armed = clock.sleeperCount
        let pause = session.requestTogglePlayPause()
        // The pause waits its turn behind the play, up to the queue wait.
        let queued = await clock.waitForSleepers(armed + 1)
        XCTAssertTrue(queued, "the pause never waited its turn behind the play")
        XCTAssertEqual(provider.commands, ["resume local"], "the pause went out before its wait ended")
        clock.advance(by: session.playPauseQueueWait)
        await pause?.value
        XCTAssertEqual(provider.commands, ["resume local", "pause local"], "the pause waited for the slow play")

        provider.releaseCommands()
        await play?.value
        XCTAssertEqual(provider.commands, ["resume local", "pause local", "pause local"], "the late play won over the last press")
        XCTAssertTrue(Self.isPaused(session))
    }

    /// Spotify on a phone: a pause on its way, then another song. The pause failing late is
    /// about the old song: the screen keeps the new one, with no refusal line.
    func testARefusalOfAPressFromBeforeANewSongChangesNothing() async {
        let (provider, session) = playingReadPlayer()
        provider.holdsCommands = true

        let pause = session.requestTogglePlayPause()
        await Self.settle { provider.waitingCommandCount == 1 }
        await session.play(uri: "music:song:2")
        let shown = session.connectionState
        provider.refusal = MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "offline")
        provider.releaseCommands()
        await pause?.value

        XCTAssertEqual(session.connectionState, shown, "the old pause's refusal put the old song's state back")
        XCTAssertNil(session.refusedPlayPause)
    }

    /// A sign-in error while a press waits for Spotify's page: the report held back for the
    /// press must not replace it when the wait ends, or the Sign In button goes away.
    func testSpotifyAHeldBackReportDoesntReplaceASignInError() async {
        let clock = ManualPlaybackClock()
        let (_, session) = playingSpotify(clock: clock)
        session.pushedPlayStateExpectationTimeout = .milliseconds(20)

        session.requestTogglePlayPause()
        session.handle(.stateChanged(Self.song, isPaused: false, nextTracks: []))
        session.handle(.authenticationError("token expired"))
        await Self.endReportWait(session.pushedPlayStateExpectationTask, of: session, on: clock)

        guard case .error = session.connectionState else {
            return XCTFail("the held-back report replaced the sign-in error: \(session.connectionState)")
        }
    }

    /// Pause takes longer than the wait in Spotify's player, the play goes out meanwhile and
    /// finishes first, then the pause lands: the play is sent again, so the last press wins.
    func testSpotifyALatePauseIsFollowedByThePlayAgain() async {
        let clock = ManualPlaybackClock()
        let (commander, session) = playingSpotify(clock: clock)
        session.inAppCommandAckTimeout = .milliseconds(20)

        await session.requestTogglePlayPause()?.value
        let pause = session.playPauseRequestSerial
        await Self.endAckWait(session, on: clock)
        await session.requestTogglePlayPause()?.value
        let play = session.playPauseRequestSerial
        session.handle(.playerCommandFinished(command: "resume", id: play))
        session.handle(.playerCommandFinished(command: "pause", id: pause))
        await Self.settle { Self.playPauseCommands(commander).count == 3 }

        XCTAssertEqual(Self.playPauseCommands(commander), [.pause, .resume, .resume], "the late pause had the last word")
        XCTAssertTrue(Self.isPlaying(session))
    }

    /// Pause accepted by the page (its report still on the way), then play refused: the player
    /// has the pause, so the controls go back to paused, not to the playing from before both.
    func testSpotifyARefusedPlayAfterAnAcceptedPauseGoesBackToThePause() async {
        let (_, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        session.handle(.playerCommandFinished(command: "pause", id: session.playPauseRequestSerial))
        await session.requestTogglePlayPause()?.value
        session.handle(.playerCommandFailed(command: "resume", message: "Spotify resume failed: offline", id: session.playPauseRequestSerial))

        XCTAssertTrue(Self.isPaused(session), "the controls went back to before the accepted pause")
        XCTAssertEqual(session.refusedPlayPause?.title, SpotiglassL10n.string("playback.refused.play"))
    }

    /// A sign-in error, then the page refuses the press it was running: the sign-in error stays,
    /// with its Sign In button.
    func testSpotifyARefusalAfterASignInErrorKeepsTheError() async {
        let (_, session) = playingSpotify()

        await session.requestTogglePlayPause()?.value
        session.handle(.authenticationError("token expired"))
        session.handle(.playerCommandFailed(command: "pause", message: "Spotify pause failed: 401", id: session.playPauseRequestSerial))

        guard case .error = session.connectionState else {
            return XCTFail("the refusal replaced the sign-in error: \(session.connectionState)")
        }
    }

    /// The wait for the page ends without the page reporting the last press: its latest report
    /// is then shown, so the bar doesn't keep a song the page has moved on from.
    func testSpotifyShowsThePagesLastReportWhenTheWaitEnds() async {
        let clock = ManualPlaybackClock()
        let (_, session) = playingSpotify(clock: clock)
        session.pushedPlayStateExpectationTimeout = .milliseconds(20)

        session.requestTogglePlayPause()
        let next = PlaybackNowPlaying(
            name: "Next", artists: ["Artist"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 180_000, positionMilliseconds: 0, uri: "spotify:track:next"
        )
        session.handle(.stateChanged(next, isPaused: false, nextTracks: []))
        XCTAssertNotEqual(session.currentNowPlaying?.name, "Next")

        await Self.endReportWait(session.pushedPlayStateExpectationTask, of: session, on: clock)
        XCTAssertEqual(session.currentNowPlaying?.name, "Next")
        XCTAssertTrue(Self.isPlaying(session))
    }

    /// Any other command the page fails still shows the error, as before.
    func testSpotifyPageFailingAnotherCommandShowsTheError() {
        let (_, session) = playingSpotify()
        session.handle(.playerCommandFailed(command: "seek", message: "Spotify seek failed: offline"))
        guard case let .error(error) = session.connectionState else {
            return XCTFail("Expected the playback error, got \(session.connectionState)")
        }
        // The page's text is a debug line in English; the bar says it in the app's language (#470).
        XCTAssertEqual(error.message, SpotiglassL10n.string("error.playback.spotify.failed"))
    }
}


/// Holds a read until the test lets it go.
@MainActor
private final class ReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }

    func hold() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
