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

    // MARK: - Queue opened in a narrow window (#413)

    private static func widen(from committed: CGFloat, to width: CGFloat) -> BrowserWidthCommitPolicy.CommitResult {
        BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: width,
                committedWidth: committed,
                lastCommitTime: 0,
                now: 1,
                comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
            )
        )
    }

    /// The sequence seen in the app: a 600-point window, the queue opens, the window widens to
    /// the queue's minimum (640) and used to bring the sidebar back, which closed the queue.
    func testOpeningTheQueueInANarrowWindowKeepsItOpen() {
        XCTAssertGreaterThan(SpotiglassDesign.detailAndQueueMinWidth, SpotiglassApp.windowMinWidth)
        XCTAssertEqual(
            SpotiglassDesign.detailAndQueueMinWidth,
            SpotiglassDesign.detailColumnMinWidth + SpotiglassDesign.queuePanelMinWidth
        )
        let toQueueMinimum = Self.widen(from: 600, to: SpotiglassDesign.detailAndQueueMinWidth)
        XCTAssertTrue(toQueueMinimum.crossedOutOfSidebarCollapse)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toQueueMinimum, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: true, isNarrow: true
            ),
            .hold
        )
        // Widened further until the sidebar, the detail column and the queue all fit.
        let toFullWidth = Self.widen(from: SpotiglassDesign.detailAndQueueMinWidth, to: 1_320)
        XCTAssertFalse(toFullWidth.crossedOutOfSidebarCollapse)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toFullWidth, sidebarCollapsed: true, heldForQueue: true, isQueueVisible: true, isNarrow: false
            ),
            .restore
        )
    }

    /// Without the queue the sidebar comes back at the same crossing as before.
    func testWideningWithoutTheQueueBringsTheSidebarBack() {
        let result = Self.widen(from: 600, to: 700)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                result, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: false, isNarrow: true
            ),
            .restore
        )
        // A sidebar the user hid stays hidden when the window grows within the wide range.
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                Self.widen(from: 1_100, to: 1_320), sidebarCollapsed: true, heldForQueue: false,
                isQueueVisible: true, isNarrow: false
            ),
            .none
        )
    }

    /// Queue opened at 600 (window grows to 640, sidebar held), then closed, then the window
    /// widened to 800: no breakpoint is crossed, but the sidebar comes back as it would have
    /// without the queue. Closing alone leaves it (restoring then would grow the window).
    func testWideningAfterClosingTheQueueBringsTheHeldSidebarBack() {
        let toOpen = Self.widen(from: 600, to: SpotiglassDesign.detailAndQueueMinWidth)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toOpen, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: true, isNarrow: true
            ),
            .hold
        )
        let to800 = Self.widen(from: SpotiglassDesign.detailAndQueueMinWidth, to: 800)
        XCTAssertFalse(to800.crossedOutOfSidebarCollapse)
        XCTAssertFalse(to800.crossedOutOfNarrow)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                to800, sidebarCollapsed: true, heldForQueue: true, isQueueVisible: false, isNarrow: true
            ),
            .restore
        )
        // A width that only jitters by less than a point isn't a widening.
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                Self.widen(from: 640, to: 640.5), sidebarCollapsed: true, heldForQueue: true,
                isQueueVisible: false, isNarrow: true
            ),
            .none
        )
        // Not held: a sidebar hidden by hand stays hidden while the window grows.
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                to800, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: false, isNarrow: true
            ),
            .none
        )
    }
}
