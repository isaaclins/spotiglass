import XCTest
@testable import Spotiglass

@MainActor
final class QueuePanelTests: XCTestCase {
    func testBridgeParsesNextTracksArray() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "nextTracks": [
                    [
                        "name": "Next Track",
                        "artists": ["Artist"],
                        "albumArtURL": "https://example.com/a.png",
                        "durationMilliseconds": 200_000,
                        "positionMilliseconds": 0,
                        "uri": "spotify:track:next"
                    ]
                ],
                "track": [
                    "name": "Current",
                    "artists": ["Artist"],
                    "durationMilliseconds": 180_000,
                    "positionMilliseconds": 0,
                    "uri": "spotify:track:current"
                ]
            ]
        ])

        guard case let .stateChanged(nowPlaying, isPaused, nextTracks) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertFalse(isPaused)
        XCTAssertEqual(nowPlaying?.uri, "spotify:track:current")
        XCTAssertEqual(nextTracks.count, 1)
        XCTAssertEqual(nextTracks.first?.name, "Next Track")
        XCTAssertEqual(nextTracks.first?.uri, "spotify:track:next")
    }

    func testQueueViewModelMergesSDKTracksWithAPIQueueSources() async {
        let api = QueueTestPlaybackAPI()
        let commander = StubWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let sdkNext = [
            PlaybackNowPlaying(name: "A", artists: ["a"], albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:a"),
            PlaybackNowPlaying(name: "B", artists: ["b"], albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:b")
        ]
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "Cur", artists: ["c"], albumArtURL: nil, durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:cur"),
            isPaused: false,
            nextTracks: sdkNext
        ))

        let trackA = SpotifyTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = SpotifyTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = SpotifyTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = SpotifyQueueResponse(
            currentlyPlaying: nil,
            queue: [.track(trackA), .track(trackB), .track(trackC)]
        )

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.count, 3)
        XCTAssertEqual(queue.upcomingItems[0].source, .sdk)
        XCTAssertEqual(queue.upcomingItems[1].source, .sdk)
        XCTAssertEqual(queue.upcomingItems[2].source, .userQueued)
    }

    func testQueueViewModelSkipsFetchWhenPanelHidden() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))

        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 50_000_000)
        queue.setPanelVisible(false)
        await queue.refreshQueue()

        XCTAssertFalse(api.actions.contains("fetchQueue"))
    }

    func testQueueViewModelAddToQueueUsesDeviceIDAndRefetches() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-42"))

        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)

        await queue.addToQueue(uri: "spotify:track:add-me")

        XCTAssertTrue(api.actions.contains("addToQueue:device-42:spotify:track:add-me"))
        XCTAssertTrue(api.actions.filter { $0 == "fetchQueue" }.count >= 1)
    }
}

private final class StubWebPlaybackCommander: WebPlaybackCommanding {
    func loadHost() {}

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {}
}

private final class QueueTestPlaybackAPI: SpotifyPlaybackControlling {
    private(set) var actions: [String] = []
    var queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [])

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        actions.append("play:\(deviceID):\(uri)")
    }

    func play(uris: [String], deviceID: String) async throws {
        actions.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func pause(deviceID: String) async throws {}

    func resume(deviceID: String) async throws {}

    func seek(to milliseconds: Int, deviceID: String) async throws {}

    func next(deviceID: String) async throws {}

    func previous(deviceID: String) async throws {}

    func fetchQueue() async throws -> SpotifyQueueResponse {
        actions.append("fetchQueue")
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actions.append("addToQueue:\(deviceID):\(uri)")
    }
}
