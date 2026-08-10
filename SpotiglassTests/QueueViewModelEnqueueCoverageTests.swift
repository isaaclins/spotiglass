import XCTest

@testable import Spotiglass

@MainActor
final class QueueViewModelEnqueueCoverageTests: XCTestCase {
    func testAddToQueueWithoutDeviceSetsPlaybackUnavailableError() async {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)

        await queue.addToQueue(uri: "spotify:track:x")

        XCTAssertNil(playback.deviceID)
        XCTAssertEqual(queue.lastError?.title, SpotiglassL10n.string("error.queue.playbackUnavailable.title"))
        XCTAssertFalse(api.actions.contains(where: { $0.hasPrefix("addToQueue:") }))
    }

    func testRateLimitedEnqueueSetsRateLimitBanner() async {
        let api = MockPlaybackAPI()
        api.addToQueueErrors = [SpotifyAPIError.rateLimited(retryAfter: 2)]
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            enqueueMinimumRetryDelay: .seconds(0)
        )

        await queue.addToQueue(uri: "spotify:track:rate")

        XCTAssertEqual(queue.lastError?.title, SpotiglassL10n.string("error.queue.rateLimited.title"))
        XCTAssertTrue(queue.lastError?.canRetry == true)
    }

    func testClearErrorRemovesBanner() async {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        await queue.addToQueue(uri: "spotify:track:x")
        XCTAssertNotNil(queue.lastError)

        queue.clearError()
        XCTAssertNil(queue.lastError)
    }

    func testPlayItemWithoutURINoOps() async {
        let api = MockPlaybackAPI()
        let commander = MockWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        let item = QueueItem(
            name: "Local",
            subtitle: "",
            albumArtURL: nil,
            durationMilliseconds: 0,
            uri: nil
        )

        await queue.playItem(item)

        XCTAssertTrue(commander.commands.isEmpty)
        XCTAssertFalse(api.actions.contains(where: { $0.hasPrefix("play:") }))
    }
}
