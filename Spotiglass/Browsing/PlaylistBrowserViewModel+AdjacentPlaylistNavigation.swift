import Foundation

extension PlaylistBrowserViewModel {
    func selectNextPlaylist() async {
        await selectAdjacentPlaylist(offset: 1)
    }

    func selectPreviousPlaylist() async {
        await selectAdjacentPlaylist(offset: -1)
    }

    static let adjacentPlaylistDebounce: Duration = .milliseconds(150)

    private func selectAdjacentPlaylist(offset: Int) async {
        pendingAdjacentPlaylistOffset += offset
        adjacentPlaylistSelectionTask?.cancel()
        let clock = adjacentPlaylistClock
        let deadline = clock.now.advanced(by: Self.adjacentPlaylistDebounce)
        adjacentPlaylistSelectionTask = Task { [weak self] in
            try? await clock.sleep(until: deadline, tolerance: nil)
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
