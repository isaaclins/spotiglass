import XCTest
@testable import Spotiglass

@MainActor
final class QueueViewModelCoreTests: XCTestCase {
    func testIsPlaybackPlayingReflectsSessionState() {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        XCTAssertFalse(queue.isPlaybackPlaying)

        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "T",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 1,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )))
        XCTAssertTrue(queue.isPlaybackPlaying)
    }

    func testHandleSdkQueueSnapshotChangeRefreshesWhenPanelVisible() async {
        let api = MockPlaybackAPI()
        let fetchQueueStarted = AsyncSignal()
        api.onFetchQueue = {
            fetchQueueStarted.signal()
        }
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)
        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "T",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 1,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )))
        queue.setPanelVisible(true)
        queue.handleSdkQueueSnapshotChanged()
        let didStartFetchQueue = await fetchQueueStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(
            didStartFetchQueue,
            "visible queue updates should fetch the REST queue"
        )
        XCTAssertTrue(api.actions.contains("fetchQueue"))
    }

    func testHandleSdkQueueSnapshotChangeNoOpsWhenPanelHidden() {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(false)
        let fetchCountBefore = api.actions.filter { $0 == "fetchQueue" }.count
        queue.handleSdkQueueSnapshotChanged()
        let fetchCountAfter = api.actions.filter { $0 == "fetchQueue" }.count
        XCTAssertEqual(fetchCountBefore, fetchCountAfter)
    }

    func testSetAppActiveNoOpsWhenUnchanged() async {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.isAppActive = true
        queue.setAppActive(true)
        queue.setPanelVisible(false)
        queue.setAppActive(false)
        XCTAssertNil(queue.pollTask)
    }

    func testQueueItemDurationLabelUsesFormatter() {
        let item = QueueItem(
            name: "T",
            subtitle: "S",
            albumArtURL: nil,
            durationMilliseconds: 125_000,
            uri: "spotify:track:1"
        )
        XCTAssertFalse(item.durationLabel.isEmpty)
    }
}
