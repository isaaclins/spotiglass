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

    /// Coalesces high-frequency geometry callbacks during window resize so `NavigationSplitView` column constraints are not rewritten every frame.
    /// When the threshold is crossed wide→narrow with both sides open, also auto-closes the LRU side.
    func commitBrowserContentWidthIfNeeded(_ newWidth: CGFloat) {
        browserWidthSampler.latestWidth = newWidth
        let now = CFAbsoluteTimeGetCurrent()
        let result = BrowserWidthCommitPolicy.evaluate(
            BrowserWidthCommitPolicy.CommitInput(
                newWidth: newWidth,
                committedWidth: browserContentWidth,
                lastCommitTime: lastBrowserWidthCommitTime,
                now: now,
                comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth
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
    }
}
