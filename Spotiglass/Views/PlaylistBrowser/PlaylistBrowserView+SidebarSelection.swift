import SwiftUI

extension PlaylistBrowserView {
    func handleSidebarSelectionChange(oldValue: SidebarSelection?, newValue: SidebarSelection?) {
        guard oldValue != newValue else { return }
        if case let .pinnedItem(id) = newValue, let item = pinnedStore.items.first(where: { $0.id == id }) {
            Task { await activatePinnedItem(item, previousSelection: oldValue) }
            return
        }
        // Track the last non-pinned selection so pinned-track clicks can
        // restore it cleanly.
        if case .pinnedItem = newValue {
            // Item not found (stale); fall through.
        } else {
            lastNonPinnedSelection = newValue
        }
        Task { await viewModel.selectSidebar(newValue) }
    }

    @MainActor
    func activatePinnedItem(_ item: PinnedItem, previousSelection: SidebarSelection?) async {
        if item.isStale {
            // Surface a notice but keep the row pinned; nothing to load.
            viewModel.sidebarSelection = previousSelection ?? lastNonPinnedSelection
            return
        }
        switch item.kind {
        case .playlist:
            guard let spotifyID = item.spotifyID else { return }
            await viewModel.selectSidebar(.playlist(spotifyID))
            syncPinnedItemStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection)
        case .artist:
            guard let spotifyID = item.spotifyID else { return }
            await viewModel.selectArtist(id: spotifyID, origin: .reset, displayName: item.title)
            syncPinnedItemStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection)
            if !itemShouldBeMarkedStale(for: viewModel.detailState) {
                viewModel.sidebarSelection = .pinnedItem(item.id)
            }
        case .album:
            guard let spotifyID = item.spotifyID else { return }
            await viewModel.selectAlbum(
                id: spotifyID,
                displayTitle: item.title,
                displaySubtitle: item.subtitle,
                artworkURL: item.artworkURL,
                origin: .reset
            )
            syncPinnedItemStaleState(item: item, fallbackSelection: previousSelection ?? lastNonPinnedSelection)
            if !itemShouldBeMarkedStale(for: viewModel.detailState) {
                viewModel.sidebarSelection = .pinnedItem(item.id)
            }
        case .likedSongs:
            viewModel.sidebarSelection = .likedSongs
        case .track:
            if let uri = item.spotifyURI {
                await playbackViewModel.play(uri: uri)
            }
            viewModel.sidebarSelection = previousSelection ?? lastNonPinnedSelection
        }
    }

    func syncPinnedItemStaleState(item: PinnedItem, fallbackSelection: SidebarSelection?) {
        let shouldMarkStale = itemShouldBeMarkedStale(for: viewModel.detailState)
        pinnedStore.markStale(id: item.id, shouldMarkStale)
        guard shouldMarkStale else { return }
        viewModel.sidebarSelection = fallbackSelection
    }

    func itemShouldBeMarkedStale(for detailState: BrowsingLoadState<BrowsingDetailContent>) -> Bool {
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

    func isPermanentPinnedLoadError(_ error: BrowsingDisplayError) -> Bool {
        let title = error.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == "not found" || title == "access denied" || title == "playlist unavailable" {
            return true
        }
        let message = error.message.lowercased()
        return message.contains("no longer accessible") || message.contains("no longer available")
    }

    /// Resolves the signed-in Spotify user ID once (best-effort) and binds the
    /// pinned-items store to it so per-account pins load from disk and future
    /// mutations persist into the right file.
    func bindPinnedStoreToCurrentUser() async {
        let profile = try? await spotifySearchClient.currentUserProfile()
        guard let userID = profile?.id else { return }
        if pinnedStore.boundUserID == userID { return }
        pinnedStore.bind(userID: userID)
    }
}
