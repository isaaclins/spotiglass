import SwiftUI

/// The browser's widths, kept outside `@State` on purpose. As `@State` each committed width
/// re-ran the whole browser body, its toolbar and the window scene on every resize step: about
/// 0.1 s per step when a window manager resizes the window from code (#473). The breakpoint rules
/// only act on the widths; the one thing on screen they decide, the sidebar's drag limit, lives in
/// ``sidebarDragLimit`` and redraws only the sidebar column's width.
@MainActor
final class BrowserWidthSampler {
    /// The width last measured.
    var latestWidth: CGFloat = 2000
    /// The width the breakpoint rules last acted on.
    var committedWidth: CGFloat = 2000
    var lastCommitTime: CFAbsoluteTime = 0
    /// The playlist sidebar's measured width; the collapse breakpoints are worked out from it,
    /// not from its declared minimum (#459).
    var playlistSidebarWidth: CGFloat = SpotiglassDesign.sidebarWidth
    /// Commits the width a resize ends on when its last frames came inside the throttle and
    /// crossed nothing. Without it the committed width stayed at an older, wider one, and the
    /// sidebar's drag limit, worked out from it, let a drag push the split view past the window.
    var trailingCommit: Timer?
    let sidebarDragLimit = SidebarDragLimit()

    /// Takes `width` as the committed one and moves the sidebar's drag limit along.
    func commit(width: CGFloat, at time: CFAbsoluteTime, isQueueVisible: Bool) {
        committedWidth = width
        lastCommitTime = time
        sidebarDragLimit.update(browserWidth: width, isQueueVisible: isQueueVisible)
    }

    /// Takes the latest measured width as the committed one (when a panel opens or closes).
    func commitLatestWidth(isQueueVisible: Bool, at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        commit(width: latestWidth, at: time, isQueueVisible: isQueueVisible)
    }
}

/// The widest the playlist sidebar can be dragged (#459). Its own object, so a new limit redraws
/// only the sidebar column's width and not the browser (#473).
@MainActor
final class SidebarDragLimit: ObservableObject {
    @Published private(set) var maxWidth = SpotiglassDesign.playlistSidebarMaxWidth(
        browserWidth: 2000, isQueueVisible: false
    )

    func update(browserWidth: CGFloat, isQueueVisible: Bool) {
        let limit = SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: browserWidth, isQueueVisible: isQueueVisible)
        guard abs(limit - maxWidth) >= 0.5 else { return }
        maxWidth = limit
    }
}

/// Gives the playlist sidebar its column width with the drag limit it observes, so only this
/// modifier runs again when the limit moves.
struct PlaylistSidebarColumnWidth: ViewModifier {
    @ObservedObject var limit: SidebarDragLimit

    func body(content: Content) -> some View {
        content.navigationSplitViewColumnWidth(
            min: SpotiglassDesign.playlistSidebarMinWidth,
            ideal: SpotiglassDesign.sidebarWidth,
            max: limit.maxWidth
        )
    }
}

/// Which column owns ⌘R / toolbar refresh when the queue panel is visible.
enum UnifiedRefreshFocus: Hashable {
    case mainContent
    case queuePanel
}

/// Identifies which side panel a user just opened so the narrow-window mutual-exclusion rule
/// can keep the most-recently-opened side and close the other.
enum SidebarKind {
    case playlist
    case queue
}

enum LibrarySidebarRow: Equatable, Identifiable {
    case home
    case pinned(PinnedItem)

    var id: String {
        switch self {
        case .home:
            return LibrarySidebarOrder.homeToken
        case let .pinned(item):
            return LibrarySidebarOrder.pinnedToken(for: item.id)
        }
    }

    var sidebarSelectionTag: SidebarSelection {
        switch self {
        case .home:
            return .home
        case let .pinned(item):
            return .pinnedItem(item.id)
        }
    }
}
