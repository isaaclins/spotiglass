import Foundation

extension PlaylistBrowserViewModel {
    func refreshSelectedPlaylist() async {
        if let sidebarSelection {
            if case .pinnedItem = sidebarSelection {
                return
            }
            detailSession += 1
            let session = detailSession
            switch sidebarSelection {
            case .playlist(let playlistID):
                try? cache.invalidateTracks(playlistID: playlistID)
                invalidateLibraryContinuationCache()
                lastTracksRevalidationByID[playlistID] = nil
            case .likedSongs:
                try? cache.invalidateTracks(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
                invalidateLibraryContinuationCache()
                lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = nil
            case .home, .search, .pinnedItem:
                break
            }
            await scheduleDetailLoad(for: sidebarSelection, refreshCachedData: false, session: session)
        } else if let artistID = artistIDForRefreshingDetail {
            await selectArtist(id: artistID, forceRefresh: true, origin: .backStackReplay, displayName: nil)
        }
    }

    /// Reloads the playlist library list (sidebar) or the current detail surface (tracks / artist).
    func unifiedRefreshMainSurface() async {
        guard let selection = sidebarSelection else {
            await refreshSelectedPlaylist()
            return
        }
        switch selection {
        case .home:
            await refreshPlaylists(trigger: .userInitiated)
            await reloadHomeSections(forceRefresh: true)
        case .search:
            // Re-runs the active query and bypasses both search caches.
            catalogSearch.refreshSearch()
        case .likedSongs, .playlist, .pinnedItem:
            await refreshSelectedPlaylist()
        }
    }

    /// Single refresh entry for toolbar, ⌘R, the View menu and the palette.
    func performUnifiedRefresh(queueRefresh: () async -> Void) async {
        // The lyrics cover the page, so Refresh would reload something you can't see. Every
        // path does nothing while they are open; the toolbar, the menu and the palette also
        // stop offering it (#438).
        if refreshRoutingLyricsPresented { return }
        if refreshRoutingQueuePanelVisible, refreshRoutingQueuePanelFocused {
            isUnifiedQueueRefreshActive = true
            defer { isUnifiedQueueRefreshActive = false }
            await queueRefresh()
            return
        }
        await unifiedRefreshMainSurface()
    }
}
