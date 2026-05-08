import SwiftUI

extension PlaylistBrowserView {
    /// True when the window is narrow enough that the playlist sidebar and queue panel must be
    /// mutually exclusive (opening one closes the other) so neither side ever clips off-screen.
    var isMutualExclusionWidth: Bool {
        Self.mutualExclusionWidth(for: browserContentWidth)
    }

    static func mutualExclusionWidth(for width: CGFloat) -> Bool {
        width < SpotiglassDesign.dualSidebarComfortableMinWidth
    }

    /// Coalesces high-frequency geometry callbacks during window resize so `NavigationSplitView` column constraints are not rewritten every frame.
    /// When the threshold is crossed wide→narrow with both sides open, also auto-closes the LRU side.
    func commitBrowserContentWidthIfNeeded(_ newWidth: CGFloat) {
        browserWidthSampler.latestWidth = newWidth
        let now = CFAbsoluteTimeGetCurrent()
        let narrowNew = Self.mutualExclusionWidth(for: newWidth)
        let narrowCommitted = Self.mutualExclusionWidth(for: browserContentWidth)
        let crossedMeaningfulBreakpoint = narrowNew != narrowCommitted
        let throttleElapsed = now - lastBrowserWidthCommitTime >= 0.06
        let largeDrift = abs(newWidth - browserContentWidth) > 120
        guard crossedMeaningfulBreakpoint || throttleElapsed || largeDrift else {
            return
        }
        lastBrowserWidthCommitTime = now
        browserContentWidth = newWidth

        if narrowNew, !narrowCommitted,
           isQueueVisible, playlistColumnVisibility != .detailOnly {
            if lastOpenedSidebar == .queue {
                playlistColumnVisibility = .detailOnly
            } else {
                isQueueVisible = false
            }
        }
    }
}
