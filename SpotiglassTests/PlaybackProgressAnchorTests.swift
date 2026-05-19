import Foundation
import XCTest
@testable import Spotiglass

final class PlaybackProgressAnchorTests: XCTestCase {
    func testPausedAnchorDoesNotAdvance() {
        let anchor = PlaybackProgressAnchor(
            positionMilliseconds: 30_000,
            anchorDate: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 180_000,
            isAdvancing: false
        )
        let later = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(anchor.interpolatedPositionMs(at: later), 30_000)
    }

    func testAdvancingAnchorInterpolatesAndClamps() {
        let start = Date(timeIntervalSince1970: 100)
        let anchor = PlaybackProgressAnchor(
            positionMilliseconds: 10_000,
            anchorDate: start,
            durationMilliseconds: 60_000,
            isAdvancing: true
        )
        XCTAssertEqual(anchor.interpolatedPositionMs(at: start.addingTimeInterval(5)), 15_000)
        XCTAssertEqual(anchor.interpolatedPositionMs(at: start.addingTimeInterval(120)), 60_000)
    }

    @MainActor
    func testReanchorOnStateChangedUpdatesAnchor() async {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 12_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))

        guard let anchor = viewModel.progressAnchor else {
            return XCTFail("Expected progress anchor while playing")
        }
        XCTAssertEqual(anchor.positionMilliseconds, 12_000)
        XCTAssertEqual(anchor.durationMilliseconds, 180_000)
        XCTAssertTrue(anchor.isAdvancing)

        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 45_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))

        XCTAssertEqual(viewModel.progressAnchor?.positionMilliseconds, 45_000)
    }
}
