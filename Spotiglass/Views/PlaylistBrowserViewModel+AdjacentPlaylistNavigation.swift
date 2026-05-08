import Foundation

extension PlaylistBrowserViewModel {
    func selectNextPlaylist() async {
        await selectAdjacentPlaylist(offset: 1)
    }

    func selectPreviousPlaylist() async {
        await selectAdjacentPlaylist(offset: -1)
    }

    private func selectAdjacentPlaylist(offset: Int) async {
        pendingAdjacentPlaylistOffset += offset
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            let order: [SidebarSelection] = [.home, .likedSongs] + self.visiblePlaylists.map { .playlist($0.id) }
            guard !order.isEmpty else { return }
            let delta = self.pendingAdjacentPlaylistOffset
            self.pendingAdjacentPlaylistOffset = 0
            let currentIndex = order.firstIndex(of: self.sidebarSelection ?? .home) ?? 0
            let nextIndex = min(max(0, currentIndex + delta), order.count - 1)
            let target = order[nextIndex]
            await self.selectSidebar(target)
        }
        await adjacentPlaylistSelectionTask?.value
    }
}
