import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackRecoveryAndPlaylistContextTests: XCTestCase {
    func testHostLifecycleClearsPendingVolumeAndBlocksStaleBridgeSend() async {
        let commander = MockWebPlaybackCommander()
        let oldVolumeSendStarted = AsyncSignal()
        let releaseOldVolumeSend = AsyncSignal()
        var didBlockVolumeSend = false
        commander.onGenerationSend = { command, _ in
            guard command == .setVolume, !didBlockVolumeSend else { return }
            didBlockVolumeSend = true
            oldVolumeSendStarted.signal()
            await releaseOldVolumeSend.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            defaults: makeEphemeralDefaults()
        )
        viewModel.deviceID = "old-device"
        viewModel.setPlaybackVolume(0.40)

        let didStartOldSend = await oldVolumeSendStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStartOldSend)
        XCTAssertNotNil(viewModel.pendingVolumeMutation)

        await viewModel.disconnect()
        XCTAssertNil(viewModel.pendingVolumeMutation)
        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration
        releaseOldVolumeSend.signal()
        await Task.yield()

        XCTAssertEqual(viewModel.playbackHostGeneration, newGeneration)
        XCTAssertFalse(commander.commands.contains {
            $0.command == .setVolume && ($0.payload["volume"] as? Double) == 0.40
        })
    }

    func testDisconnectDuringStartupRemainsDisconnectedAfterLateSDKEvents() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        commander.onSend = { command in
            guard command == .connect else { return }
            connectStarted.signal()
            await releaseConnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander))

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)

        await viewModel.disconnect()
        viewModel.handle(MusicPlaybackEventEnvelope(event: .ready(deviceID: "old-device"), hostGeneration: oldGeneration))
        viewModel.handle(MusicPlaybackEventEnvelope(event: .notReady(deviceID: "old-device"), hostGeneration: oldGeneration))
        viewModel.handle(MusicPlaybackEventEnvelope(event: .initializationError("old startup failed"), hostGeneration: oldGeneration))
        releaseConnect.signal()
        await Task.yield()

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNil(viewModel.deviceID)
        XCTAssertFalse(viewModel.autoResumeOnNextReady)
        XCTAssertFalse(playbackAPI.actions.contains { $0.hasPrefix("transfer:") })
    }

    func testDisconnectDuringNotReadyRecoveryPreventsOldRecoveryCompletion() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var connectCount = 0
        commander.onSend = { command in
            guard command == .connect else { return }
            connectCount += 1
            if connectCount == 1 {
                connectStarted.signal()
                await releaseConnect.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))
        let recoveryTask = viewModel.playbackHostRecoveryTask

        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)
        await viewModel.disconnect()
        releaseConnect.signal()
        await recoveryTask?.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertEqual(commander.loadHostCallCount, 0)
        XCTAssertEqual(connectCount, 1)
    }

    func testFreshStartDuringDisconnectSendPreservesNewLifecycle() async {
        let commander = MockWebPlaybackCommander()
        let disconnectStarted = AsyncSignal()
        let releaseDisconnect = AsyncSignal()
        commander.onSend = { command in
            guard command == .disconnect else { return }
            disconnectStarted.signal()
            await releaseDisconnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander))
        viewModel.handle(.ready(deviceID: "old-device"))

        let disconnectTask = Task {
            await viewModel.disconnect()
        }
        let didDisconnectStart = await disconnectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didDisconnectStart)

        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(viewModel.autoResumeOnNextReady)
        XCTAssertEqual(commander.loadHostCallCount, 1)
        viewModel.handle(.ready(deviceID: "new-device"))
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))

        releaseDisconnect.signal()
        await disconnectTask.value

        XCTAssertEqual(viewModel.playbackHostGeneration, newGeneration)
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))
        XCTAssertEqual(viewModel.deviceID, "new-device")
    }

    func testDisconnectDuringInitializationRecoveryPreventsOldRecoveryCompletion() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var connectCount = 0
        commander.onSend = { command in
            guard command == .connect else { return }
            connectCount += 1
            if connectCount == 1 {
                connectStarted.signal()
                await releaseConnect.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        viewModel.handle(.initializationError("SDK init failed"))
        let recoveryTask = viewModel.playbackHostRecoveryTask
        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)
        await viewModel.disconnect()
        releaseConnect.signal()
        await recoveryTask?.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertEqual(commander.loadHostCallCount, 0)
        XCTAssertEqual(connectCount, 1)
    }

    func testStaleConnectCompletionCannotSendIntoFreshHostGeneration() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var blockedGeneration: PlaybackHostGeneration?
        commander.onGenerationSend = { command, generation in
            guard command == .connect, blockedGeneration == nil else { return }
            blockedGeneration = generation
            connectStarted.signal()
            await releaseConnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander))

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        let oldConnectTask = viewModel.playbackHostConnectTask
        let didStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        XCTAssertEqual(blockedGeneration, oldGeneration)

        await viewModel.disconnect()
        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration
        let newConnectTask = viewModel.playbackHostConnectTask
        releaseConnect.signal()
        await oldConnectTask?.value
        await newConnectTask?.value

        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertEqual(
            commander.commands.filter { $0.command == .connect }.count,
            1,
            "The stale connect must be dropped after a fresh host generation is loaded."
        )
        XCTAssertEqual(commander.commands.first(where: { $0.command == .connect })?.command, .connect)
    }

    func testExplicitReconnectCreatesFreshGenerationAndRetainsRecoveryBehavior() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            // Long enough that recovery stops at its first connect attempt for
            // the duration of this test. This test is about generation
            // fencing, not about escalation; with 10ms timeouts the chain
            // raced ahead into repeated hard reloads and crashed the CI test
            // host in runs 32508559474, 32521200807 and 32548893141.
            // `testInitializationErrorRunsReuseAttemptsBeforeHardReload` is
            // the test that deliberately drives the escalation.
            playbackHostRecoveryConnectTimeout: .seconds(30),
            playbackHostRecoverySoftResetTimeout: .seconds(30)
        )
        let recoveryConnectStarted = AsyncSignal()
        commander.onSend = { command in
            guard command == .connect,
                  viewModel.playbackHostReuseConnectAttemptCount >= 1 else { return }
            recoveryConnectStarted.signal()
        }

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        await viewModel.disconnect()
        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration

        XCTAssertNotEqual(oldGeneration, newGeneration)
        viewModel.handle(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "old-device"),
            hostGeneration: oldGeneration
        ))
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertNil(viewModel.deviceID)

        viewModel.handle(MusicPlaybackEventEnvelope(
            event: .ready(deviceID: "new-device"),
            hostGeneration: newGeneration
        ))
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))

        viewModel.handle(MusicPlaybackEventEnvelope(
            event: .notReady(deviceID: "new-device"),
            hostGeneration: newGeneration
        ))
        let didStartRecoveryConnect = await recoveryConnectStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(
            didStartRecoveryConnect,
            "recovery should issue a host reuse connect"
        )

        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseConnectAttemptCount, 1)
        XCTAssertTrue(commander.commands.contains { $0.command == .connect })

        // Cancels the in-flight recovery so it cannot outlive the view model.
        await viewModel.disconnect()
    }

    func testConnectingResolvesToRetryableErrorAfterTimeout() async {
        let commander = MockWebPlaybackCommander()
        let clock = ManualPlaybackClock()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            clock: clock,
            playbackHostConnectTimeout: .milliseconds(20)
        )

        viewModel.start()
        await Self.endConnectTimeout(of: viewModel, on: clock)

        guard case let .error(error) = viewModel.connectionState else {
            return XCTFail("Expected a connection timeout error")
        }
        XCTAssertEqual(error, PlaybackSessionViewModel.playbackHostConnectionTimedOutError())
        XCTAssertEqual(error.recoveryAction, .reconnect)
        XCTAssertTrue(commander.commands.contains { $0.command == .connect })
    }

    func testStaleReadyDoesNotCancelConnectionTimeout() async {
        let clock = ManualPlaybackClock()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()),
            clock: clock,
            playbackHostConnectTimeout: .milliseconds(20)
        )

        viewModel.handle(.ready(deviceID: "old-device"))
        viewModel.handle(.notReady(deviceID: "old-device"))
        viewModel.start()
        viewModel.handle(.ready(deviceID: "old-device"))
        await Self.endConnectTimeout(of: viewModel, on: clock)

        guard case let .error(error) = viewModel.connectionState else {
            return XCTFail("Expected a connection timeout after ignoring stale ready")
        }
        XCTAssertEqual(error.recoveryAction, .reconnect)
    }

    /// Lets the connect timeout run out on the session's stepped clock, once it is armed (#510).
    private static func endConnectTimeout(of viewModel: PlaybackSessionViewModel, on clock: ManualPlaybackClock) async {
        let armed = await clock.waitForSleepers()
        XCTAssertTrue(armed, "no connect timeout is armed")
        let timeout = viewModel.playbackHostConnectTimeoutTask
        XCTAssertNotNil(timeout, "no connect timeout is armed")
        clock.advance(by: viewModel.playbackHostConnectTimeout)
        await timeout?.value
    }

    func testRetryPlaybackTransferCallsTransferAPIWhenDeviceKnown() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander))
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.playbackError("Slow down"))

        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, ["transfer:device-1:false"])
        guard case let .ready(id) = viewModel.connectionState else {
            return XCTFail("Expected ready after retry transfer")
        }
        XCTAssertEqual(id, "device-1")
        XCTAssertEqual(viewModel.deviceID, "device-1")
    }

    // MARK: Retry after a failed command (#451)

    private static func playingTrack(_ uri: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: uri
        )
    }

    private static func retryError(of viewModel: PlaybackSessionViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .error(error) = viewModel.connectionState else {
            return XCTFail("Expected the failure in the bar", file: file, line: line)
        }
        XCTAssertEqual(error.recoveryAction, .retryTransfer, file: file, line: line)
    }

    /// A Play that hits a network error, then Retry right away: the song asked for is sent
    /// again. Before, Retry only moved playback here with `play: false` and the song never started.
    func testRetryAfterAFailedPlayPlaysTheSongAgain() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(Self.playingTrack("spotify:track:old"), isPaused: false, nextTracks: []))
        api.playErrors = [URLError(.notConnectedToInternet)]

        await viewModel.play(uri: "spotify:track:asked")
        Self.retryError(of: viewModel)
        XCTAssertTrue(viewModel.retriesFailedCommand)
        XCTAssertFalse(api.actions.contains("play:device-1:spotify:track:asked"))

        await viewModel.retryAfterError()

        XCTAssertEqual(api.actions.filter { $0 == "play:device-1:spotify:track:asked" }.count, 1)
        XCTAssertEqual(api.actions.filter { $0 != "fetchPlayerSnapshot" }.last, "play:device-1:spotify:track:asked")
        XCTAssertNil(viewModel.connectionStateError, "Retry clears the error while the play goes out")
        XCTAssertFalse(viewModel.retriesFailedCommand)
    }

    func testRetryAfterAFailedPlayFromAListPlaysThatListAgain() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        api.playErrors = [URLError(.timedOut)]

        await viewModel.playFromPlaylist(clickedURI: "spotify:track:b", playableURIs: ["spotify:track:a", "spotify:track:b"], playlistID: "list")
        Self.retryError(of: viewModel)

        await viewModel.retryAfterError()

        XCTAssertEqual(api.actions.filter { $0 == "play-list:device-1:spotify:track:a,spotify:track:b" }.count, 1)
        XCTAssertEqual(api.lastPlayedOffsetURI, "spotify:track:b")
        XCTAssertEqual(viewModel.activePlaylistID, "list")
    }

    func testRetryAfterAFailedNextSkipsAgain() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(Self.playingTrack("spotify:track:1"), isPaused: false, nextTracks: []))
        api.nextError = URLError(.notConnectedToInternet)

        await viewModel.next()
        Self.retryError(of: viewModel)
        api.nextError = nil

        // Right after the failure, inside the spacing between two skips.
        await viewModel.retryAfterError()

        XCTAssertEqual(api.actions.filter { $0 == "next:device-1" }.count, 1)
        XCTAssertFalse(api.actions.contains { $0.hasPrefix("transfer:") })
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Retry goes back to the song that was playing")
        }
        XCTAssertEqual(nowPlaying.uri, "spotify:track:1")
    }

    func testRetryAfterAFailedSeekSeeksAgain() async {
        let api = MockPlaybackAPI()
        api.seekError = URLError(.networkConnectionLost)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .milliseconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(Self.playingTrack("spotify:track:1"), isPaused: false, nextTracks: []))

        await viewModel.seek(to: 92_000)
        await viewModel.seekDispatchTask?.value
        Self.retryError(of: viewModel)
        api.seekError = nil

        await viewModel.retryAfterError()
        await viewModel.seekDispatchTask?.value

        XCTAssertEqual(api.actions.filter { $0 == "seek:device-1:92000" }.count, 1)
        XCTAssertNil(viewModel.connectionStateError)
    }

    func testRetryAfterAFailedShuffleAndRepeatSendsThemAgain() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        api.setShuffleError = URLError(.notConnectedToInternet)
        api.setRepeatError = URLError(.notConnectedToInternet)
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()
        Self.retryError(of: viewModel)
        api.setShuffleError = nil
        await viewModel.retryAfterError()
        XCTAssertTrue(viewModel.shuffleEnabled)
        XCTAssertTrue(api.actions.contains("setShuffle:device-1:true"))

        await viewModel.setRepeatMode(.context)
        Self.retryError(of: viewModel)
        api.setRepeatError = nil
        await viewModel.retryAfterError()
        XCTAssertEqual(viewModel.repeatMode, .context)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:context"))
    }

    /// A failure of moving playback here keeps its Retry: it moves playback here again.
    func testRetryAfterAPlayerErrorStillMovesPlaybackHere() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        api.playErrors = [URLError(.notConnectedToInternet)]
        await viewModel.play(uri: "spotify:track:asked")
        // The player's own error comes after the failed play and replaces it.
        viewModel.handle(.playbackError("Slow down"))
        XCTAssertFalse(viewModel.retriesFailedCommand)
        let actionsBeforeRetry = api.actions.count

        await viewModel.retryAfterError()

        XCTAssertEqual(Array(api.actions.dropFirst(actionsBeforeRetry)).filter { $0 != "fetchPlayerSnapshot" }, ["transfer:device-1:false"])
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "device-1"))
    }

    func testRetryPlaybackTransferWithoutDeviceStartsPlaybackHost() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander))

        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(commander.didLoadHost)
    }

    func testRetryPlaybackTransferWithoutDeviceUsesBoundedHardReloadBudget() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            playbackHostHardReloadCooldown: .seconds(5),
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        await viewModel.retryPlaybackTransfer()
        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(commander.loadHostCallCount, 1, "Second rapid recovery should be suppressed by host reload cooldown.")
        XCTAssertEqual(viewModel.playbackHostReloadAttemptCount, 1)
        XCTAssertEqual(viewModel.playbackHostReloadSuppressedCooldownCount, 1)
    }

    func testInitializationErrorRunsReuseAttemptsBeforeHardReload() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander),
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )
        let hardReloadStarted = AsyncSignal()
        commander.onLoadHost = { _ in
            hardReloadStarted.signal()
        }

        viewModel.handle(.initializationError("SDK init failed"))
        let didStartHardReload = await hardReloadStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(
            didStartHardReload,
            "recovery should escalate to a hard host reload"
        )

        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseConnectAttemptCount, 1)
        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseSoftResetAttemptCount, 1)
        XCTAssertEqual(commander.loadHostCallCount, 1, "Transient init recovery should escalate to a single hard reload after reuse attempts.")

        await viewModel.disconnect()
    }

    func testPremiumAccountErrorMapsToClearState() {
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))

        viewModel.handle(.accountError("Premium required"))

        guard case let .error(error) = viewModel.connectionState else {
            return XCTFail("Expected error")
        }
        XCTAssertEqual(error.title, "Spotify Premium required")
        // The SDK's English text is replaced by the app's own sentence (#470).
        XCTAssertEqual(error.message, SpotiglassL10n.string("error.playback.premium.message"))
        XCTAssertNil(error.recoveryAction)
    }

    func testUnavailableDeviceStateIsExplicit() {
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))

        viewModel.handle(.notReady(deviceID: "device-1"))

        XCTAssertNil(viewModel.deviceID)
        guard case let .unavailable(message) = viewModel.connectionState else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertTrue(message.contains("no longer available"))
    }

    func testStartReconnectsFromErrorAndUnavailableStates() async {
        let commander = MockWebPlaybackCommander()
        let connectSent = AsyncSignal()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander))
        commander.onSend = { command in
            guard command == .connect else { return }
            connectSent.signal()
        }

        // Simulate a Play attempt before the SDK reported a device:
        // the view model lands in the "device unavailable" error state.
        await viewModel.play(uri: "spotify:track:1")
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected error after play without device")
        }
        XCTAssertEqual(displayError.title, "Playback device unavailable")

        // Choosing Reconnect from the error state must restart the SDK host.
        viewModel.start()
        let didSendConnect = await connectSent.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didSendConnect,
            "reconnect should send the SDK connect command"
        )

        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.last?.command, .connect)

        // Simulate the SDK eventually losing its device, then reconnecting again.
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))
        guard case .unavailable = viewModel.connectionState else {
            return XCTFail("Expected unavailable state after not_ready")
        }
        viewModel.start()
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertNil(viewModel.deviceID)
    }

    func testPlayURIOptimisticallyResetsPositionForKnownCurrentTrack() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander))
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 32_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))

        await viewModel.play(uri: "spotify:track:1")

        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing state")
        }
        XCTAssertEqual(nowPlaying.positionMilliseconds, 0)
        XCTAssertEqual(nowPlaying.uri, "spotify:track:1")
    }

    func testPlayFromPlaylistSendsCompleteURIListWithClickedTrackOffset() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:track:2",
                "spotify:episode:3",
                "spotify:track:4"
            ]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play-list:device-1:spotify:track:1,spotify:track:2,spotify:episode:3,spotify:track:4"
        ])
        XCTAssertEqual(playbackAPI.lastPlayedURIQueue, [
            "spotify:track:1",
            "spotify:track:2",
            "spotify:episode:3",
            "spotify:track:4"
        ])
        XCTAssertEqual(playbackAPI.lastPlayedOffsetURI, "spotify:track:2")
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:track:2")
    }

    func testPlayFromPlaylistIncludesEpisodesInQueueOrder() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:episode:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:episode:2",
                "spotify:track:3"
            ]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play-list:device-1:spotify:track:1,spotify:episode:2,spotify:track:3"
        ])
    }

    func testPlayFromPlaylistFallsBackToSingleTrackWhenClickedURIMissing() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:missing",
            playableURIs: ["spotify:track:1", "spotify:track:2"]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:missing"
        ])
    }

    func testActivePlaylistIDIsSetByPlayFromPlaylistAndClearedByPlayURI() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))

        XCTAssertNil(viewModel.activePlaylistID)

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:1",
            playableURIs: ["spotify:track:1", "spotify:track:2"],
            playlistID: "playlist-42"
        )
        XCTAssertEqual(viewModel.activePlaylistID, "playlist-42")

        await viewModel.play(uri: "spotify:track:standalone")
        XCTAssertNil(viewModel.activePlaylistID)
    }

    func testPlayURISuppressesStaleStateChangedEventsForPreviousTrack() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander))
        viewModel.handle(.ready(deviceID: "device-1"))

        // Establish a current track via the SDK.
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 50_000,
            uri: "spotify:track:old"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))
        guard case let .playing(initial) = viewModel.connectionState else {
            return XCTFail("Expected .playing after initial stateChanged")
        }
        XCTAssertEqual(initial.uri, "spotify:track:old")

        // User asks to play a new track. Until the SDK confirms it, any
        // mid-transition state event still showing the old URI must be
        // suppressed so the now-playing label does not jitter back.
        await viewModel.play(uri: "spotify:track:new")

        let staleOld = oldTrack.with(positionMilliseconds: 51_000)
        viewModel.handle(.stateChanged(staleOld, isPaused: false, nextTracks: []))
        guard case let .playing(afterStale) = viewModel.connectionState else {
            return XCTFail("Expected stale event to leave previous state intact")
        }
        XCTAssertEqual(
            afterStale.uri,
            "spotify:track:old",
            "Stale event for previous track should not change the connection state because the user already requested a new track."
        )
        XCTAssertEqual(
            afterStale.positionMilliseconds,
            initial.positionMilliseconds,
            "Stale event for the previous track must not advance position either."
        )

        // Once the SDK confirms the new track, the gating clears and the
        // event is applied normally.
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: ["B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:new"
        )
        viewModel.handle(.stateChanged(newTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterNew) = viewModel.connectionState else {
            return XCTFail("Expected .playing after new track confirmed")
        }
        XCTAssertEqual(afterNew.uri, "spotify:track:new")
    }

    func testActivePlaylistIDClearedByDisconnect() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:1",
            playableURIs: ["spotify:track:1"],
            playlistID: "playlist-9"
        )
        XCTAssertEqual(viewModel.activePlaylistID, "playlist-9")

        await viewModel.disconnect()
        XCTAssertNil(viewModel.activePlaylistID)
    }
}
