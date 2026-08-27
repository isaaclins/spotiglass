import XCTest
@testable import Spotiglass

@MainActor
final class LyricsOverlayControllerTests: XCTestCase {
    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.tearDown()
    }

    func testAttachDetachAndDismiss() async {
        let controller = LyricsOverlayController()
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }

        controller.attach(
            playback: playback,
            queue: queue,
            lyrics: lyrics,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        XCTAssertNotNil(controller.playbackViewModel)
        XCTAssertNotNil(controller.queueViewModel)
        XCTAssertNotNil(controller.lyricsModel)

        controller.isPresented = true
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertNotNil(controller.playbackViewModel)

        controller.detach()
        XCTAssertNil(controller.playbackViewModel)
        XCTAssertNil(controller.queueViewModel)
        XCTAssertNil(controller.lyricsModel)
        XCTAssertFalse(controller.isPresented)
    }

    func testDetachingOneSceneLeavesAnotherSceneOverlayAttached() {
        let first = LyricsOverlayController()
        let second = LyricsOverlayController()

        let firstAPI = MockPlaybackAPI()
        let firstPlayback = PlaybackSessionViewModel(
            playbackAPI: firstAPI,
            webCommander: MockWebPlaybackCommander()
        )
        let firstQueue = QueueViewModel(
            playbackAPI: firstAPI,
            playbackSession: firstPlayback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        first.attach(
            playback: firstPlayback,
            queue: firstQueue,
            lyrics: ImmersiveLyricsViewModel { _ in .instrumental },
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )

        let secondAPI = MockPlaybackAPI()
        let secondPlayback = PlaybackSessionViewModel(
            playbackAPI: secondAPI,
            webCommander: MockWebPlaybackCommander()
        )
        let secondQueue = QueueViewModel(
            playbackAPI: secondAPI,
            playbackSession: secondPlayback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        second.attach(
            playback: secondPlayback,
            queue: secondQueue,
            lyrics: ImmersiveLyricsViewModel { _ in .instrumental },
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        first.isPresented = true
        second.isPresented = true

        first.detach()

        XCTAssertFalse(first.isPresented)
        XCTAssertTrue(second.isPresented)
        XCTAssertTrue(second.playbackViewModel === secondPlayback)
        XCTAssertTrue(second.queueViewModel === secondQueue)
        XCTAssertNotNil(second.lyricsModel)
    }
}
