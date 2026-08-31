import XCTest
@testable import Spotiglass

final class PlaylistBrowserWidthPolicyTests: XCTestCase {
    func testMutualExclusionBelowComfortableWidth() {
        XCTAssertTrue(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 400, comfortableMinWidth: 900))
        XCTAssertFalse(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 1000, comfortableMinWidth: 900))
    }

    func testSidebarCollapseMinimumComesFromColumnMinimums() {
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarAndDetailMinWidth,
            SpotiglassDesign.playlistSidebarMinWidth + SpotiglassDesign.detailColumnMinWidth
        )
    }

    func testEvaluateSkipsWhenNoBreakpointThrottleOrDrift() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 1000,
                committedWidth: 995,
                lastCommitTime: 10,
                now: 10.01,
                comfortableMinWidth: 900,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
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
                comfortableMinWidth: 900,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
            )
        )
        XCTAssertTrue(result.shouldCommit)
        XCTAssertTrue(result.crossedIntoNarrow)
        XCTAssertEqual(result.committedWidth, 800)
        XCTAssertFalse(result.crossedIntoSidebarCollapse)
        XCTAssertFalse(result.crossedOutOfSidebarCollapse)
    }

    func testEvaluateCollapsesSidebarWhenWidthCrossesColumnMinimum() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 600,
                committedWidth: 700,
                lastCommitTime: 10,
                now: 10.01,
                comfortableMinWidth: 900,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
            )
        )

        XCTAssertTrue(result.shouldCommit)
        XCTAssertTrue(result.crossedIntoSidebarCollapse)
        XCTAssertFalse(result.crossedOutOfSidebarCollapse)
    }

    func testEvaluateRestoresSidebarWhenWidthCrossesColumnMinimumUpward() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 700,
                committedWidth: 600,
                lastCommitTime: 10,
                now: 10.01,
                comfortableMinWidth: 900,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
            )
        )

        XCTAssertTrue(result.shouldCommit)
        XCTAssertFalse(result.crossedIntoSidebarCollapse)
        XCTAssertTrue(result.crossedOutOfSidebarCollapse)
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
