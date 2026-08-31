import CoreFoundation
import Foundation

/// Pure width-commit rules for playlist browser chrome (sidebar/detail and queue mutual exclusion).
enum BrowserWidthCommitPolicy {
    static func mutualExclusionWidth(for width: CGFloat, comfortableMinWidth: CGFloat) -> Bool {
        width < comfortableMinWidth
    }

    struct CommitInput {
        var newWidth: CGFloat
        var committedWidth: CGFloat
        var lastCommitTime: CFAbsoluteTime
        var now: CFAbsoluteTime
        var comfortableMinWidth: CGFloat
        /// Minimum width at which the playlist sidebar and detail columns can coexist.
        var sidebarCollapseMinWidth: CGFloat
        var throttleSeconds: CGFloat = 0.06
        var largeDriftPoints: CGFloat = 120
    }

    struct CommitResult {
        var shouldCommit: Bool
        var committedWidth: CGFloat
        var lastCommitTime: CFAbsoluteTime
        var crossedIntoNarrow: Bool
        var crossedIntoSidebarCollapse: Bool
        var crossedOutOfSidebarCollapse: Bool
    }

    static func evaluate(_ input: CommitInput) -> CommitResult {
        let narrowNew = mutualExclusionWidth(for: input.newWidth, comfortableMinWidth: input.comfortableMinWidth)
        let narrowCommitted = mutualExclusionWidth(for: input.committedWidth, comfortableMinWidth: input.comfortableMinWidth)
        let sidebarCollapseNew = mutualExclusionWidth(
            for: input.newWidth,
            comfortableMinWidth: input.sidebarCollapseMinWidth
        )
        let sidebarCollapseCommitted = mutualExclusionWidth(
            for: input.committedWidth,
            comfortableMinWidth: input.sidebarCollapseMinWidth
        )
        let crossedMeaningfulBreakpoint = narrowNew != narrowCommitted
        let crossedIntoSidebarCollapse = sidebarCollapseNew && !sidebarCollapseCommitted
        let crossedOutOfSidebarCollapse = !sidebarCollapseNew && sidebarCollapseCommitted
        let throttleElapsed = input.now - input.lastCommitTime >= Double(input.throttleSeconds)
        let largeDrift = abs(input.newWidth - input.committedWidth) > input.largeDriftPoints
        let shouldCommit =
            crossedMeaningfulBreakpoint
            || crossedIntoSidebarCollapse
            || crossedOutOfSidebarCollapse
            || throttleElapsed
            || largeDrift
        guard shouldCommit else {
            return CommitResult(
                shouldCommit: false,
                committedWidth: input.committedWidth,
                lastCommitTime: input.lastCommitTime,
                crossedIntoNarrow: false,
                crossedIntoSidebarCollapse: false,
                crossedOutOfSidebarCollapse: false
            )
        }
        return CommitResult(
            shouldCommit: true,
            committedWidth: input.newWidth,
            lastCommitTime: input.now,
            crossedIntoNarrow: narrowNew && !narrowCommitted,
            crossedIntoSidebarCollapse: crossedIntoSidebarCollapse,
            crossedOutOfSidebarCollapse: crossedOutOfSidebarCollapse
        )
    }

    enum SidebarToCloseOnNarrow: Equatable {
        case playlistColumn
        case queue
    }

    static func sidebarToCloseOnNarrow(
        lastOpenedSidebar: SidebarToCloseOnNarrow,
        isQueueVisible: Bool,
        playlistColumnIsDetailOnly: Bool
    ) -> SidebarToCloseOnNarrow? {
        guard isQueueVisible, !playlistColumnIsDetailOnly else { return nil }
        switch lastOpenedSidebar {
        case .queue:
            return .playlistColumn
        case .playlistColumn:
            return .queue
        }
    }
}
