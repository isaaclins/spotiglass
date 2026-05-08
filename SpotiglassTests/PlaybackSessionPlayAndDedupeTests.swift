import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackSessionPlayAndDedupeTests: XCTestCase {
    func testPlaybackSessionTransitionsFromConnectingToReadyAndPlaying() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        viewModel.start()
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
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.first?.command, .connect)
        XCTAssertTrue(commander.commands.contains { $0.command == .setVolume })
        XCTAssertEqual(viewModel.deviceID, "device-1")
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing")
        }
        XCTAssertEqual(nowPlaying.name, "Track")
    }

    func testReadySyncsPlaybackVolumeToWebPlayer() async {
        UserDefaults.standard.removeObject(forKey: "spotiglass.playbackVolume")
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let volumeCommands = commander.commands.filter { $0.command == .setVolume }
        XCTAssertEqual(volumeCommands.count, 1)
        let sent = volumeCommands[0].payload["volume"] as? Double
        XCTAssertNotNil(sent)
        XCTAssertEqual(sent!, PlaybackSessionViewModel.defaultPlaybackVolume, accuracy: 0.001)
    }

    func testSetPlaybackVolumePersistsAndSendsBridgeCommand() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        viewModel.setPlaybackVolume(0.56)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.playbackVolume, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(commander.commands.last?.command, .setVolume)
        let lastVolume = commander.commands.last?.payload["volume"] as? Double
        XCTAssertNotNil(lastVolume)
        XCTAssertEqual(lastVolume!, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "spotiglass.playbackVolume"), 0.56, accuracy: 0.000_001)
        UserDefaults.standard.removeObject(forKey: "spotiglass.playbackVolume")
    }

    func testPlayURITransfersPlaybackBeforePlayCommand() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1"
        ])
        XCTAssertEqual(commander.commands.last?.command, .playURI)
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:track:1")
    }

    func testPlayCommandTriggerMatrixListsExpectedEntrypoints() {
        let matrix = PlaybackSessionViewModel.playCommandTriggerMatrix
        XCTAssertTrue(matrix.contains { $0.entrypoint == "play(uri:)" })
        XCTAssertTrue(matrix.contains { $0.entrypoint == "play(contextURI:)" })
        XCTAssertTrue(matrix.contains { $0.entrypoint == "playFromPlaylist(clickedURI:playableURIs:playlistID:)" })
    }

    func testDuplicatePlayURIWithinWindowIsDeduped() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:1")

        XCTAssertEqual(playbackAPI.actions, [
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
        playbackAPI.playDelayNanoseconds = 150_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        try? await Task.sleep(nanoseconds: 20_000_000)
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

        let playTask = Task { await viewModel.play(uri: "spotify:track:1") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(playbackAPI.actions.contains("fetchPlayerSnapshot"))
        await playTask.value
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(playbackAPI.actions.contains("fetchPlayerSnapshot"))
    }

    func testPlayURIDoesNotTransferAgainForConsecutiveTrackSwitchesOnSameDevice() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:2")

        XCTAssertEqual(playbackAPI.actions, [
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

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1",
            "transfer:device-1:false",
            "play:device-1:spotify:track:2"
        ])
    }

}
