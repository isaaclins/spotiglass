import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackSessionPlayAndDedupeTests: XCTestCase {
    func testPlaybackSessionTransitionsFromConnectingToReadyAndPlaying() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        // In production `.ready` arrives from the web player only after `connect`
        // was sent; mirror that ordering here instead of racing the connect task.
        let connectSent = AsyncSignal()
        let volumeSent = AsyncSignal()
        commander.onSend = { command in
            if command == .connect { connectSent.signal() }
            if command == .setVolume { volumeSent.signal() }
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        viewModel.start()
        await connectSent.wait()
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))
        await volumeSent.wait()

        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.first?.command, .connect)
        XCTAssertTrue(commander.commands.contains { $0.command == .setVolume })
        XCTAssertEqual(viewModel.deviceID, "device-1")
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing")
        }
        XCTAssertEqual(nowPlaying.name, "Track")
    }

    func testReadyWithoutCachedSnapshotStartsInitialTransportSyncImmediately() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )

        XCTAssertNil(viewModel.latestPlayerSnapshot)
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        XCTAssertTrue(
            playbackAPI.actions.contains("fetchPlayerSnapshot"),
            "SDK ready should start transport synchronization without the no-snapshot poll delay."
        )
    }

    func testReadyAndConcurrentSyncCallersShareOneInitialTransportFetch() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.fetchPlayerSnapshotDelayNanoseconds = 100_000_000
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        async let firstSync: Void = viewModel.syncTransportFromSpotify()
        async let secondSync: Void = viewModel.syncTransportFromSpotify()
        _ = await (firstSync, secondSync)

        XCTAssertEqual(
            playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            1,
            "Ready and concurrent sync callers must share one initial transport read."
        )
    }

    func testDisconnectDuringInFlightTransportSyncSuppressesLateSnapshotMutation() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: true, repeatMode: .track),
            activeDevice: SpotifyConnectDevice(
                deviceID: "old-device",
                isActive: true,
                isRestricted: false,
                name: "Old device",
                type: "computer"
            ),
            isPlaying: true
        )]
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        playbackAPI.onFetchPlayerSnapshot = {
            fetchStarted.signal()
            await releaseFetch.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "old-device"))
        let initialTransportSyncTask = viewModel.transportSyncSchedulerTask

        let didStart = await fetchStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        await viewModel.disconnect()
        playbackAPI.onFetchPlayerSnapshot = nil
        releaseFetch.signal()
        await initialTransportSyncTask?.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNil(viewModel.latestPlayerSnapshot)
        XCTAssertFalse(viewModel.isTransportStateKnown)
        XCTAssertFalse(viewModel.shuffleEnabled)
        XCTAssertEqual(viewModel.repeatMode, .off)
        XCTAssertNil(viewModel.activePlaybackDeviceID)
    }

    func testDuplicateReadyForKnownCurrentDevicePreservesTransportStateWithoutAnotherFetch() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: true, repeatMode: .track),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        let fetchCountAfterInitialSync = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        viewModel.handle(.ready(deviceID: "device-1"))

        XCTAssertTrue(viewModel.isTransportStateKnown)
        XCTAssertTrue(viewModel.shuffleEnabled)
        XCTAssertEqual(viewModel.repeatMode, .track)
        XCTAssertEqual(
            playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            fetchCountAfterInitialSync,
            "A duplicate ready event for the current known device must not start another sync."
        )
    }

    func testReadyFencesPersistedVolumeBeforeInitialTransportSnapshotCompletes() async {
        let playbackAPI = MockPlaybackAPI()
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        playbackAPI.onFetchPlayerSnapshot = {
            fetchStarted.signal()
            await releaseFetch.wait()
        }
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 20
            ),
            isPlaying: false
        )]
        let defaults = makeEphemeralDefaults()
        defaults.set(0.64, forKey: "spotiglass.playbackVolume")
        let commander = MockWebPlaybackCommander()
        let persistedVolumeSent = AsyncSignal()
        commander.onSendWithPayload = { command, payload in
            guard command == .setVolume,
                  let volume = payload["volume"] as? Double,
                  abs(volume - 0.64) < 0.000_001 else { return }
            persistedVolumeSent.signal()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: commander,
            defaults: defaults
        )

        viewModel.handle(.ready(deviceID: "device-1"))
        let didStartFetch = await fetchStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStartFetch)
        XCTAssertEqual(try XCTUnwrap(viewModel.pendingVolumeMutation).target, 0.64, accuracy: 0.000_001)

        releaseFetch.signal()
        for _ in 0..<1_000 where viewModel.latestPlayerSnapshot?.activeDevice?.volumePercent != 20 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.latestPlayerSnapshot?.activeDevice?.volumePercent, 20)
        XCTAssertEqual(viewModel.playbackVolume, 0.64, accuracy: 0.000_001)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.64, accuracy: 0.000_001)

        let didSendPersistedVolume = await persistedVolumeSent.wait(timeout: .seconds(1))
        XCTAssertTrue(didSendPersistedVolume)
        XCTAssertEqual(try XCTUnwrap(commander.commands.last?.payload["volume"] as? Double), 0.64, accuracy: 0.000_001)
    }

    func testReadySyncsPlaybackVolumeToWebPlayer() async {
        let commander = MockWebPlaybackCommander()
        let volumeSent = AsyncSignal()
        commander.onSend = { command in
            if command == .setVolume { volumeSent.signal() }
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            defaults: makeEphemeralDefaults()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let didSendReadyVolume = await volumeSent.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didSendReadyVolume,
            "ready should send the persisted playback volume"
        )
        let volumeCommands = commander.commands.filter { $0.command == .setVolume }
        XCTAssertEqual(volumeCommands.count, 1)
        let sent = volumeCommands[0].payload["volume"] as? Double
        XCTAssertNotNil(sent)
        XCTAssertEqual(sent!, PlaybackSessionViewModel.defaultPlaybackVolume, accuracy: 0.001)
    }

    func testRapidPlaybackVolumeChangesLeaveLatestBridgeCommandAuthoritative() async {
        let commander = MockWebPlaybackCommander()
        let latestCommandSent = AsyncSignal()
        commander.onSendWithPayload = { command, payload in
            guard command == .setVolume,
                  let volume = payload["volume"] as? Double,
                  abs(volume - 0.85) < 0.000_001 else { return }
            latestCommandSent.signal()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            defaults: makeEphemeralDefaults()
        )

        viewModel.setPlaybackVolume(0.25)
        viewModel.setPlaybackVolume(0.85)

        let didSendLatest = await latestCommandSent.wait(timeout: .seconds(1))
        XCTAssertTrue(didSendLatest)
        XCTAssertEqual(viewModel.volumeMutationVersion, 2)
        XCTAssertEqual(viewModel.playbackVolume, 0.85, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(commander.commands.last?.payload["volume"] as? Double), 0.85, accuracy: 0.000_001)
    }

    func testSetPlaybackVolumePersistsAndSendsBridgeCommand() async {
        let commander = MockWebPlaybackCommander()
        let defaults = makeEphemeralDefaults()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            defaults: defaults
        )
        let volumeSent = AsyncSignal()
        commander.onSend = { command in
            if command == .setVolume { volumeSent.signal() }
        }
        viewModel.setPlaybackVolume(0.56)
        let didSendVolume = await volumeSent.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didSendVolume,
            "setting playback volume should send its bridge command"
        )
        XCTAssertEqual(viewModel.playbackVolume, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(commander.commands.last?.command, .setVolume)
        let lastVolume = commander.commands.last?.payload["volume"] as? Double
        XCTAssertNotNil(lastVolume)
        XCTAssertEqual(lastVolume!, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.56, accuracy: 0.000_001)
    }

    func testTransportResponseStartedBeforeLocalVolumeChangeCannotOverwriteIt() async {
        let playbackAPI = MockPlaybackAPI()
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        playbackAPI.onFetchPlayerSnapshot = {
            fetchStarted.signal()
            await releaseFetch.wait()
        }
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 20
            ),
            isPlaying: false
        )]
        let defaults = makeEphemeralDefaults()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: defaults
        )
        viewModel.deviceID = "device-1"

        let syncTask = Task { await viewModel.syncTransportFromSpotify() }
        let didStartFetch = await fetchStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStartFetch)
        viewModel.setPlaybackVolume(0.75)
        releaseFetch.signal()
        await syncTask.value

        XCTAssertEqual(viewModel.playbackVolume, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.75, accuracy: 0.000_001)
    }

    func testMismatchingTransportVolumeConvergesAfterPendingDeadline() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: makeEphemeralDefaults(),
            pendingVolumeTimeout: .zero
        )
        viewModel.deviceID = "device-1"
        viewModel.setPlaybackVolume(0.80)
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 30
            ),
            isPlaying: false
        )]

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.playbackVolume, 0.30, accuracy: 0.000_001)
        XCTAssertNil(viewModel.pendingVolumeMutation)
    }

    func testMatchingTransportVolumeAcknowledgesPendingLocalTarget() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: makeEphemeralDefaults()
        )
        viewModel.deviceID = "device-1"
        viewModel.setPlaybackVolume(0.80)
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 80
            ),
            isPlaying: false
        )]

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.playbackVolume, 0.80, accuracy: 0.000_001)
        XCTAssertNil(viewModel.pendingVolumeMutation)
    }

    func testRemoteTransportDeviceVolumeDoesNotChangeLocalPlaybackVolume() async {
        let playbackAPI = MockPlaybackAPI()
        let defaults = makeEphemeralDefaults()
        defaults.set(0.70, forKey: "spotiglass.playbackVolume")
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "remote-device",
                isActive: true,
                isRestricted: false,
                name: "Phone",
                type: "smartphone",
                volumePercent: 20
            ),
            isPlaying: true
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: defaults
        )
        viewModel.deviceID = "local-device"

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.playbackVolume, 0.70, accuracy: 0.000_001)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.70, accuracy: 0.000_001)
    }

    func testMismatchingTransportVolumeDoesNotOverwritePendingLocalTarget() async {
        let playbackAPI = MockPlaybackAPI()
        let defaults = makeEphemeralDefaults()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: defaults
        )
        viewModel.deviceID = "device-1"
        viewModel.setPlaybackVolume(0.80)
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 30
            ),
            isPlaying: false
        )]

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.playbackVolume, 0.80, accuracy: 0.000_001)
        XCTAssertNotNil(viewModel.pendingVolumeMutation)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.80, accuracy: 0.000_001)
    }

    func testTransportSnapshotUpdatesPlaybackVolumeForCurrentLocalDevice() async {
        let playbackAPI = MockPlaybackAPI()
        let defaults = makeEphemeralDefaults()
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "device-1",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer",
                volumePercent: 30
            ),
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            defaults: defaults
        )
        viewModel.deviceID = "device-1"

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.playbackVolume, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.30, accuracy: 0.000_001)
    }

    func testPlayURITransfersPlaybackBeforePlayCommand() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1"
        ])
        XCTAssertEqual(commander.commands.last?.command, .playURI)
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:track:1")
    }

    func testDuplicatePlayURIWithinWindowIsDeduped() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        playbackAPI.playDelayNanoseconds = 150_000_000

        async let firstPlay: Void = viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:1")
        await firstPlay

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1"
        ])
        XCTAssertEqual(viewModel.playCommandAttemptedCount, 2)
        XCTAssertEqual(viewModel.playCommandDedupedCount, 1)
        XCTAssertEqual(viewModel.playCommandSentCount, 1)
    }

    func testDifferentPlayCommandsIncrementSupersededCounterWhenOverlapping() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        // Deterministic overlap, no wall-clock racing: the first play parks inside the
        // mock (still in flight for the dispatch bookkeeping) until the second play's
        // API call arrives — and reaching the mock means the second dispatch has
        // already counted the supersession.
        let firstPlayEntered = AsyncSignal()
        let releaseFirstPlay = AsyncSignal()
        playbackAPI.onPlay = { uri in
            if uri == "spotify:track:1" {
                firstPlayEntered.signal()
                await releaseFirstPlay.wait()
            } else if uri == "spotify:track:2" {
                releaseFirstPlay.signal()
            }
        }

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        await firstPlayEntered.wait()
        async let second: Void = viewModel.play(uri: "spotify:track:2")
        _ = await (first, second)

        XCTAssertEqual(viewModel.playCommandSentCount, 2)
        XCTAssertGreaterThanOrEqual(viewModel.playCommandSupersededCount, 1)
    }

    func testTransportSyncDefersWhilePlayCommandIsInFlight() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.playDelayNanoseconds = 180_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        let initialFetchCount = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count
        let playStarted = AsyncSignal()
        let deferredSyncStarted = AsyncSignal()
        playbackAPI.onPlay = { _ in
            playStarted.signal()
        }
        playbackAPI.onFetchPlayerSnapshot = {
            if playbackAPI.actions.filter({ $0 == "fetchPlayerSnapshot" }).count > initialFetchCount {
                deferredSyncStarted.signal()
            }
        }

        let playTask = Task { await viewModel.play(uri: "spotify:track:1") }
        let didStartPlay = await playStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartPlay,
            "the play command should be in flight before the transport sync"
        )
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(
            playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            initialFetchCount,
            "Transport reads should defer while the play command is in flight."
        )
        await playTask.value
        let didStartDeferredSync = await deferredSyncStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartDeferredSync,
            "a deferred transport sync should run after the play command completes"
        )
        XCTAssertGreaterThan(
            playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            initialFetchCount
        )
    }

    func testPlayURIDoesNotTransferAgainForConsecutiveTrackSwitchesOnSameDevice() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:2")

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1",
            "play:device-1:spotify:track:2"
        ])
    }

    func testPlayURITransfersAgainAfterDeviceBecomesNotReady() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        viewModel.handle(.notReady(deviceID: "device-1"))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.play(uri: "spotify:track:2")

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1",
            "transfer:device-1:false",
            "play:device-1:spotify:track:2"
        ])
    }

}
