import Foundation

/// Pure helpers for pinned-sidebar activation and stale detection in the playlist browser.
enum PlaylistBrowserPinnedSidebarPolicy {
    static func itemShouldBeMarkedStale(for detailState: BrowsingLoadState<BrowsingDetailContent>) -> Bool {
        switch detailState {
        case let .error(error):
            return isPermanentPinnedLoadError(error)
        case let .staleCache(_, error):
            if let error {
                return isPermanentPinnedLoadError(error)
            }
            return false
        case .loading, .loaded, .empty, .refreshing:
            return false
        }
    }

    static func isPermanentPinnedLoadError(_ error: BrowsingDisplayError) -> Bool {
        let title = error.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == "not found" || title == "access denied" || title == "playlist unavailable" {
            return true
        }
        let message = error.message.lowercased()
        return message.contains("no longer accessible") || message.contains("no longer available")
    }
}
