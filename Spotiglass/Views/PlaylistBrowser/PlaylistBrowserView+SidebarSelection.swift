import SwiftUI

extension PlaylistBrowserView {
    func handleSidebarSelectionChange(oldValue: SidebarSelection?, newValue: SidebarSelection?) {
        Task { @MainActor in
            switch PlaylistBrowserSidebarSelectionHandling.selectionChangeAction(
                oldValue: oldValue,
                newValue: newValue,
                pinnedItems: pinnedStore.items
            ) {
            case .none:
                break
            case .activatePinned(let item):
                await activatePinnedItem(item, previousSelection: oldValue)
            case .selectSidebar(let selection):
                lastNonPinnedSelection = PlaylistBrowserSidebarSelectionHandling.lastNonPinnedSelection(
                    afterSelecting: selection
                )
                await viewModel.selectSidebar(selection)
            }
        }
    }

    @MainActor
    func activatePinnedItem(_ item: PinnedItem, previousSelection: SidebarSelection?) async {
        let browserVM = viewModel
        let playbackVM = playbackViewModel
        let store = pinnedStore
        await PlaylistBrowserSidebarSelectionHandling.activatePinnedItem(
            item,
            previousSelection: previousSelection,
            lastNonPinnedSelection: lastNonPinnedSelection,
            callbacks: .init(
                setSidebarSelection: { browserVM.sidebarSelection = $0 },
                selectSidebarPlaylist: { id in await browserVM.selectSidebar(.playlist(id)) },
                selectArtist: { id, origin, name in
                    await browserVM.selectArtist(id: id, origin: origin, displayName: name)
                },
                selectAlbum: { id, title, subtitle, artwork, origin in
                    await browserVM.selectAlbum(
                        id: id,
                        displayTitle: title,
                        displaySubtitle: subtitle,
                        artworkURL: artwork,
                        origin: origin
                    )
                },
                playURI: { uri in await playbackVM.play(uri: uri) },
                markStale: { id, stale in store.markStale(id: id, stale) },
                detailState: { browserVM.detailState }
            )
        )
    }

    func syncPinnedItemStaleState(item: PinnedItem, fallbackSelection: SidebarSelection?) {
        let shouldMarkStale = itemShouldBeMarkedStale(for: viewModel.detailState)
        pinnedStore.markStale(id: item.id, shouldMarkStale)
        guard shouldMarkStale else { return }
        viewModel.sidebarSelection = fallbackSelection
    }

    func itemShouldBeMarkedStale(for detailState: BrowsingLoadState<BrowsingDetailContent>) -> Bool {
        PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: detailState)
    }

    func isPermanentPinnedLoadError(_ error: BrowsingDisplayError) -> Bool {
        PlaylistBrowserPinnedSidebarPolicy.isPermanentPinnedLoadError(error)
    }

    func bindPinnedStoreToCurrentUser() async {
        let profile = try? await spotifySearchClient.currentUserProfile()
        guard let userID = profile?.id else { return }
        if pinnedStore.boundUserID == userID { return }
        pinnedStore.bind(userID: userID)
    }
}
