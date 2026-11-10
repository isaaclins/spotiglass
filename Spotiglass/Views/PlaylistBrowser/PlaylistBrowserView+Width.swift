import SwiftUI

extension PlaylistBrowserView {
    /// True when the window is narrow enough that the playlist sidebar and queue panel must be
    /// mutually exclusive (opening one closes the other) so neither side ever clips off-screen.
    var isMutualExclusionWidth: Bool {
        Self.mutualExclusionWidth(
            for: browserWidthSampler.committedWidth,
            sidebarWidth: browserWidthSampler.playlistSidebarWidth
        )
    }

    static func mutualExclusionWidth(for width: CGFloat, sidebarWidth: CGFloat) -> Bool {
        BrowserWidthCommitPolicy.mutualExclusionWidth(
            for: width,
            comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: sidebarWidth)
        )
    }

    /// Keeps the width the sidebar really has, which decides when it no longer fits (#459). A
    /// collapsed sidebar keeps the last one: that is the width it comes back at.
    func recordPlaylistSidebarWidth(_ width: CGFloat) {
        guard playlistColumnVisibility != .detailOnly,
              width >= SpotiglassDesign.playlistSidebarMinWidth - 0.5,
              abs(width - browserWidthSampler.playlistSidebarWidth) >= 0.5
        else { return }
        browserWidthSampler.playlistSidebarWidth = width
    }

    /// Once the throttle has passed, commits the newest width a skipped frame measured, so the
    /// committed width always ends on the width the window really has. A run loop timer in the
    /// common modes, so it also fires while a live resize keeps the run loop tracking events.
    private func scheduleTrailingBrowserWidthCommit() {
        let sampler = browserWidthSampler
        guard sampler.trailingCommit == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                sampler.trailingCommit = nil
                commitBrowserContentWidthIfNeeded(sampler.latestWidth)
            }
        }
        sampler.trailingCommit = timer
        RunLoop.main.add(timer, forMode: .common)
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
                committedWidth: browserWidthSampler.committedWidth,
                lastCommitTime: browserWidthSampler.lastCommitTime,
                now: now,
                comfortableMinWidth: SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: browserWidthSampler.playlistSidebarWidth),
                sidebarCollapseMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(
                    sidebarWidth: browserWidthSampler.playlistSidebarWidth
                )
            )
        )
        guard result.shouldCommit else {
            scheduleTrailingBrowserWidthCommit()
            return
        }
        browserWidthSampler.trailingCommit?.invalidate()
        browserWidthSampler.trailingCommit = nil
        browserWidthSampler.commit(width: result.committedWidth, at: result.lastCommitTime, isQueueVisible: isQueueVisible)

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
            return
        }
        switch BrowserWidthCommitPolicy.sidebarOnWidening(
            result,
            sidebarCollapsed: playlistColumnVisibility == .detailOnly,
            heldForQueue: isSidebarHeldForQueue,
            isQueueVisible: isQueueVisible,
            isNarrow: isMutualExclusionWidth
        ) {
        case .none:
            break
        case .hold:
            isSidebarHeldForQueue = true
        case .restore:
            isSidebarHeldForQueue = false
            playlistColumnVisibility = .doubleColumn
        }
    }
}
