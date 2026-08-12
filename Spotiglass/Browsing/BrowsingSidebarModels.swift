import Foundation

enum SidebarSelection: Hashable {
    case home
    /// Dedicated full-window catalog search surface (sidebar row above Home).
    case search
    case likedSongs
    case playlist(String)
    /// Pinned-area row identified by ``PinnedItem.id``. The browser view
    /// routes the click through ``PinnedItemsStore`` to dispatch the right
    /// detail loader (or playback for pinned tracks).
    case pinnedItem(String)
}

enum BrowserNavigationTarget: Equatable {
    case sidebar(SidebarSelection)
    case artist(String)
    case album(id: String, title: String, subtitle: String, artworkURL: URL?)
}

/// Logical drill-in path shown in the window toolbar (separate from ``backNavigationStack``).
struct BrowserBreadcrumb: Equatable, Identifiable {
    enum Kind: Equatable {
        case search
        case likedSongs
        case playlist(id: String)
        case artist(id: String)
        case album(id: String, title: String, subtitle: String, artworkURL: URL?)
    }

    let id: UUID
    let label: String
    let systemImage: String
    let kind: Kind
}

enum BrowserNavigationOrigin {
    /// New navigation started from sidebar, palette, pins, or lyrics overlay — replaces the trail root.
    case reset
    /// In-page drill-in (track artist tap, album card, related artist) — appends one segment.
    case extend
    /// Replay navigation without mutating ``breadcrumbPath`` (back button, crumb tap, refresh-in-place).
    case backStackReplay
}

enum PlaylistRefreshTrigger {
    case automatic
    case userInitiated
}
