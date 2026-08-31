import SwiftUI

extension PlaylistBrowserView {
    /// True when the window is narrow enough that the playlist sidebar and queue panel must be
    /// mutually exclusive (opening one closes the other) so neither side ever clips off-screen.
    var isMutualExclusionWidth: Bool {
        Self.mutualExclusionWidth(for: browserContentWidth)
    }

    static func mutualExclusionWidth(for width: CGFloat) -> Bool {
        BrowserWidthCommitPolicy.mutualExclusionWidth(
            for: width,
            comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth
        )
    }

    /// Coalesces high-frequency geometry callbacks during window resize so
    /// `NavigationSplitView` column constraints are not rewritten every frame.
    /// The committed width drives both the queue mutual-exclusion rule and the
    /// independent sidebar/detail minimum-width collapse.
    func commitBrowserContentWidthIfNeeded(_ newWidth: CGFloat) {
        browserWidthSampler.latestWidth = newWidth
        let now = CFAbsoluteTimeGetCurrent()
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: newWidth,
                committedWidth: browserContentWidth,
                lastCommitTime: lastBrowserWidthCommitTime,
                now: now,
                comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth,
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth
            )
        )
        guard result.shouldCommit else { return }
        lastBrowserWidthCommitTime = result.lastCommitTime
        browserContentWidth = result.committedWidth

        if result.crossedIntoNarrow,
           isQueueVisible, playlistColumnVisibility != .detailOnly {
            let lastOpened: BrowserWidthCommitPolicy.SidebarToCloseOnNarrow =
                lastOpenedSidebar == .queue ? .queue : .playlistColumn
            switch BrowserWidthCommitPolicy.sidebarToCloseOnNarrow(
                lastOpenedSidebar: lastOpened,
                isQueueVisible: isQueueVisible,
                playlistColumnIsDetailOnly: playlistColumnVisibility == .detailOnly
            ) {
            case .playlistColumn:
                playlistColumnVisibility = .detailOnly
            case .queue:
                isQueueVisible = false
            case .none:
                break
            }
        }

        if result.crossedIntoSidebarCollapse {
            playlistColumnVisibility = .detailOnly
        } else if result.crossedOutOfSidebarCollapse,
                  playlistColumnVisibility == .detailOnly {
            playlistColumnVisibility = .doubleColumn
        }
    }
}
