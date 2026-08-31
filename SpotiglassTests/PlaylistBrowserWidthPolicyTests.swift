import XCTest
@testable import Spotiglass

final class PlaylistBrowserWidthPolicyTests: XCTestCase {
    func testMutualExclusionBelowComfortableWidth() {
        XCTAssertTrue(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 400, comfortableMinWidth: 900))
        XCTAssertFalse(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 1000, comfortableMinWidth: 900))
    }

    func testEvaluateSkipsWhenNoBreakpointThrottleOrDrift() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 1000,
                committedWidth: 995,
                lastCommitTime: 10,
                now: 10.01,
                comfortableMinWidth: 900
            )
        )
        XCTAssertFalse(result.shouldCommit)
    }

    func testEvaluateCommitsOnBreakpointCross() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 800,
                committedWidth: 1000,
                lastCommitTime: 0,
                now: 1,
                comfortableMinWidth: 900
            )
        )
        XCTAssertTrue(result.shouldCommit)
        XCTAssertTrue(result.crossedIntoNarrow)
        XCTAssertEqual(result.committedWidth, 800)
    }

    func testSidebarToClosePrefersPlaylistWhenQueueOpenedLast() {
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarToCloseOnNarrow(
                lastOpenedSidebar: .queue,
                isQueueVisible: true,
                playlistColumnIsDetailOnly: false
            ),
            .playlistColumn
        )
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarToCloseOnNarrow(
                lastOpenedSidebar: .playlistColumn,
                isQueueVisible: true,
                playlistColumnIsDetailOnly: false
            ),
            .queue
        )
    }
}
