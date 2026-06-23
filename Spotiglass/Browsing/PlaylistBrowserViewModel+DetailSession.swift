import Foundation

extension PlaylistBrowserViewModel {
    func scheduleDetailLoad(for selection: SidebarSelection, refreshCachedData: Bool, session: Int) async {
        // Drop any shift-click track selection — row ids belong to the
        // previous detail surface, not the one we're about to load.
        clearTrackSelection()
        detailLoadTask?.cancel()
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDetail(for: selection, refreshCachedData: refreshCachedData, session: session)
        }
        detailLoadTask = task
        await task.value
        if generation == detailLoadGeneration {
            detailLoadTask = nil
        }
    }

    private func loadDetail(for selection: SidebarSelection, refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        switch selection {
        case .home:
            await loadHomeFeed(session: session)
        case .likedSongs:
            await loadLikedSongsTracks(refreshCachedData: refreshCachedData, session: session)
        case let .playlist(playlistID):
            await loadTracks(for: playlistID, refreshCachedData: refreshCachedData, session: session)
        case .pinnedItem:
            guard session == detailSession else { return }
            return
        }
    }
}
