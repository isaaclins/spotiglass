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
