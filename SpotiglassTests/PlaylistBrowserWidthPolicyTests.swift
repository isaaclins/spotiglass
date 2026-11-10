import XCTest
@testable import Spotiglass

final class PlaylistBrowserWidthPolicyTests: XCTestCase {
    func testMutualExclusionBelowComfortableWidth() {
        XCTAssertTrue(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 400, comfortableMinWidth: 900))
        XCTAssertFalse(BrowserWidthCommitPolicy.mutualExclusionWidth(for: 1000, comfortableMinWidth: 900))
    }

    /// The breakpoint follows the sidebar's real width, never less than its minimum (#459).
    func testSidebarCollapseMinimumComesFromTheSidebarsRealWidth() {
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: 320),
            320 + SpotiglassDesign.detailColumnMinWidth + 8
        )
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: 410),
            410 + SpotiglassDesign.detailColumnMinWidth + 8
        )
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: 0),
            SpotiglassDesign.playlistSidebarMinWidth + SpotiglassDesign.detailColumnMinWidth + 8
        )
        // Where the sidebar and the queue stop fitting together didn't move for the default sidebar.
        XCTAssertEqual(SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: 320), 1_000)
        XCTAssertEqual(
            SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: 410)
                - SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: 320),
            90
        )
    }

    /// A dragged sidebar leaves the detail column (and an open queue) their minimums (#459).
    func testSidebarMaxWidthLeavesRoomForTheColumnsBesideIt() {
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: 800, isQueueVisible: false),
            800 - SpotiglassDesign.detailColumnMinWidth - 8
        )
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: 1_200, isQueueVisible: true),
            1_200 - SpotiglassDesign.detailColumnMinWidth - 8 - SpotiglassDesign.queuePanelMinWidth - 32
        )
        XCTAssertEqual(
            SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: 500, isQueueVisible: false),
            SpotiglassDesign.playlistSidebarMinWidth
        )
    }

    /// A sidebar dragged as wide as it goes leaves the browser above both breakpoints, so a
    /// narrower window still crosses them. With the queue open the limit used to be 40 pt past
    /// the width where the sidebar and the queue can both stay open: in a 1200 pt window a drag
    /// to 560 made the window narrow without crossing into it, and shrinking the window then
    /// closed neither of them.
    func testADraggedSidebarStillLetsANarrowerWindowCrossTheBreakpoints() {
        for browser: CGFloat in [700, 800, 1_000, 1_200, 1_600] {
            for queue in [false, true] {
                let sidebar = SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: browser, isQueueVisible: queue)
                let collapseAt = SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: sidebar)
                let narrowAt = SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: sidebar)
                XCTAssertGreaterThanOrEqual(browser, collapseAt, "\(browser) pt, queue \(queue)")
                // Narrower than this the queue and the sidebar can't both be open at any width.
                let roomForBoth = SpotiglassDesign.dualSidebarComfortableMinWidth(
                    sidebarWidth: SpotiglassDesign.playlistSidebarMinWidth
                )
                guard queue, browser >= roomForBoth else { continue }
                XCTAssertGreaterThanOrEqual(browser, narrowAt, "\(browser) pt with the queue")
                let shrunk = BrowserWidthCommitPolicy.evaluate(
                    BrowserWidthCommitPolicy.CommitInput(
                        newWidth: browser - 10,
                        committedWidth: browser,
                        lastCommitTime: 10,
                        now: 10.01,
                        comfortableMinWidth: narrowAt,
                        sidebarCollapseMinWidth: collapseAt
                    )
                )
                XCTAssertTrue(shrunk.crossedIntoNarrow, "\(browser) pt with the queue")
            }
        }
    }

    /// The window from #459: the sidebar keeps its 320 pt while the window shrinks from 700 to
    /// 640, where it and the detail column's 360 pt no longer fit. The sidebar has to collapse
    /// there, not only below 280 + 360.
    func testSidebarCollapsesWhereItsRealWidthNoLongerFits() {
        let sidebar = SpotiglassDesign.sidebarWidth
        func shrink(from committed: CGFloat, to width: CGFloat) -> BrowserWidthCommitPolicy.CommitResult {
            BrowserWidthCommitPolicy.evaluate(
                BrowserWidthCommitPolicy.CommitInput(
                    newWidth: width,
                    committedWidth: committed,
                    lastCommitTime: 10,
                    now: 10.01,
                    comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: sidebar),
                    sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: sidebar)
                )
            )
        }
        XCTAssertFalse(shrink(from: 900, to: 700).crossedIntoSidebarCollapse)
        // macOS 26's split view takes 8 pt more than its two columns: at 680 it ran 4 pt past
        // each edge of the window.
        XCTAssertFalse(shrink(from: 700, to: sidebar + SpotiglassDesign.detailColumnMinWidth + 8).crossedIntoSidebarCollapse)
        XCTAssertTrue(shrink(from: 700, to: sidebar + SpotiglassDesign.detailColumnMinWidth).crossedIntoSidebarCollapse)
        XCTAssertTrue(shrink(from: 700, to: 660).crossedIntoSidebarCollapse)
        XCTAssertTrue(shrink(from: 700, to: 640).crossedIntoSidebarCollapse)
    }

    func testEvaluateSkipsWhenNoBreakpointThrottleOrDrift() {
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: 1000,
                committedWidth: 995,
                lastCommitTime: 10,
                now: 10.01,
                comfortableMinWidth: 900,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
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
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
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
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
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
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
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
                comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth),
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
            )
        )
    }

    /// The sequence seen in the app: a 600-point window, the queue opens, the window widens to
    /// the queue's minimum (640) and used to bring the sidebar back, which closed the queue.
    /// At 640 the sidebar doesn't fit next to the detail column at all (#459), so it stays
    /// collapsed; widening past its room holds it for the queue.
    func testOpeningTheQueueInANarrowWindowKeepsItOpen() {
        XCTAssertGreaterThan(SpotiglassDesign.detailAndQueueMinWidth, SpotiglassApp.windowMinWidth)
        XCTAssertEqual(
            SpotiglassDesign.detailAndQueueMinWidth,
            SpotiglassDesign.detailColumnMinWidth + SpotiglassDesign.queuePanelMinWidth
        )
        let toQueueMinimum = Self.widen(from: 600, to: SpotiglassDesign.detailAndQueueMinWidth)
        XCTAssertFalse(toQueueMinimum.crossedOutOfSidebarCollapse)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toQueueMinimum, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: true, isNarrow: true
            ),
            .none
        )
        let toSidebarRoom = Self.widen(from: SpotiglassDesign.detailAndQueueMinWidth, to: 700)
        XCTAssertTrue(toSidebarRoom.crossedOutOfSidebarCollapse)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toSidebarRoom, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: true, isNarrow: true
            ),
            .hold
        )
        // Widened further until the sidebar, the detail column and the queue all fit.
        let toFullWidth = Self.widen(from: 700, to: 1_320)
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

    /// Queue opened at 600 (window grows to 640), widened to 700 (sidebar held), the queue
    /// closed, then the window widened to 800: no breakpoint is crossed, but the sidebar comes
    /// back as it would have without the queue. Closing alone leaves it (restoring then would
    /// grow the window).
    func testWideningAfterClosingTheQueueBringsTheHeldSidebarBack() {
        let toOpen = Self.widen(from: SpotiglassDesign.detailAndQueueMinWidth, to: 700)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                toOpen, sidebarCollapsed: true, heldForQueue: false, isQueueVisible: true, isNarrow: true
            ),
            .hold
        )
        let to800 = Self.widen(from: 700, to: 800)
        XCTAssertFalse(to800.crossedOutOfSidebarCollapse)
        XCTAssertFalse(to800.crossedOutOfNarrow)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                to800, sidebarCollapsed: true, heldForQueue: true, isQueueVisible: false, isNarrow: true
            ),
            .restore
        )
        // Shrunk below the sidebar's room first: widening within that range keeps it hidden,
        // widening past it brings it back.
        let within = Self.widen(from: 520, to: 600)
        XCTAssertFalse(within.widenedWithRoomForSidebar)
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                within, sidebarCollapsed: true, heldForQueue: true, isQueueVisible: false, isNarrow: true
            ),
            .none
        )
        XCTAssertEqual(
            BrowserWidthCommitPolicy.sidebarOnWidening(
                Self.widen(from: 600, to: 700), sidebarCollapsed: true, heldForQueue: true,
                isQueueVisible: false, isNarrow: true
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
