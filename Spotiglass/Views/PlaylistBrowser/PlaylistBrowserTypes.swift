import SwiftUI

/// Holds the latest measured browser width without `@State` updates so resize drags do not thrash SwiftUI.
final class BrowserWidthSampler {
    var latestWidth: CGFloat = 2000
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
    case search
    case home
    case pinned(PinnedItem)

    var id: String {
        switch self {
        case .search:
            return LibrarySidebarOrder.searchToken
        case .home:
            return LibrarySidebarOrder.homeToken
        case .pinned(let item):
            return LibrarySidebarOrder.pinnedToken(for: item.id)
        }
    }

    var sidebarSelectionTag: SidebarSelection {
        switch self {
        case .search:
            return .search
        case .home:
            return .home
        case .pinned(let item):
            return .pinnedItem(item.id)
        }
    }
}
