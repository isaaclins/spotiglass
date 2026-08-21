import Foundation

/// Sidebar selection and pinned-item activation extracted from ``PlaylistBrowserView`` for isolated unit tests.
@MainActor
enum PlaylistBrowserSidebarSelectionHandling {
    enum SelectionChangeAction: Equatable {
        case none
        case activatePinned(PinnedItem)
        case selectSidebar(SidebarSelection?)
    }

    static func selectionChangeAction(
        oldValue: SidebarSelection?,
        newValue: SidebarSelection?,
        pinnedItems: [PinnedItem]
    ) -> SelectionChangeAction {
        guard oldValue != newValue else { return .none }
        if case let .pinnedItem(id) = newValue,
           let item = pinnedItems.first(where: { $0.id == id }) {
            return .activatePinned(item)
        }
        if case .pinnedItem = newValue {
            return .selectSidebar(newValue)
        }
        return .selectSidebar(newValue)
    }

    static func lastNonPinnedSelection(
        afterSelecting newValue: SidebarSelection?
    ) -> SidebarSelection? {
        switch newValue {
        case .pinnedItem:
            return nil
        default:
            return newValue
        }
    }

    struct ActivationCallbacks {
        var setSidebarSelection: (SidebarSelection?) -> Void
        var selectSidebarPlaylist: (SpotifyPlaylistSummary) async -> Void
        var selectArtist: (String, BrowserNavigationOrigin, String?) async -> Void
        var selectAlbum: (String, String, String, URL?, BrowserNavigationOrigin) async -> Void
        var playURI: (String) async -> Void
        var markStale: (String, Bool) -> Void
        var detailState: () -> BrowsingLoadState<BrowsingDetailContent>
    }

    static func activatePinnedItem(
        _ item: PinnedItem,
        previousSelection: SidebarSelection?,
        lastNonPinnedSelection: SidebarSelection?,
        callbacks: ActivationCallbacks
    ) async {
        guard let route = PlaylistBrowserPinnedItemActivation.route(
            for: item,
            previousSelection: previousSelection ?? lastNonPinnedSelection
        ) else { return }

        switch route {
        case let .staleRevert(selection):
            let revert: SidebarSelection?
            if case .pinnedItem = selection {
                revert = lastNonPinnedSelection
            } else {
                revert = selection ?? lastNonPinnedSelection
            }
            callbacks.setSidebarSelection(revert)
        case let .selectPlaylist(summary):
            await callbacks.selectSidebarPlaylist(summary)
            syncPinnedStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection, callbacks: callbacks)
        case let .selectArtist(id, displayName):
            await callbacks.selectArtist(id, .reset, displayName)
            syncPinnedStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection, callbacks: callbacks)
            if let selection = PlaylistBrowserPinnedItemActivation.sidebarSelectionAfterActivation(
                item: item,
                detailState: callbacks.detailState()
            ) {
                callbacks.setSidebarSelection(selection)
            }
        case let .selectAlbum(id, title, subtitle, artworkURL):
            await callbacks.selectAlbum(id, title, subtitle, artworkURL, .reset)
            syncPinnedStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection, callbacks: callbacks)
            if let selection = PlaylistBrowserPinnedItemActivation.sidebarSelectionAfterActivation(
                item: item,
                detailState: callbacks.detailState()
            ) {
                callbacks.setSidebarSelection(selection)
            }
        case .likedSongs:
            callbacks.setSidebarSelection(.likedSongs)
        case let .playTrack(uri, revertSelection):
            await callbacks.playURI(uri)
            callbacks.setSidebarSelection(revertSelection)
        }
    }

    private static func syncPinnedStaleState(
        item: PinnedItem,
        fallbackSelection: SidebarSelection?,
        callbacks: ActivationCallbacks
    ) {
        let shouldMarkStale = PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: callbacks.detailState())
        callbacks.markStale(item.id, shouldMarkStale)
        guard shouldMarkStale else { return }
        callbacks.setSidebarSelection(fallbackSelection)
    }
}
