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
                lastTracksRevalidationByID[playlistID] = nil
            case .likedSongs:
                try? cache.invalidateTracks(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
                lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = nil
            case .home, .pinnedItem:
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
            await reloadHomeSections()
        case .likedSongs, .playlist, .pinnedItem:
            await refreshSelectedPlaylist()
        }
    }

    /// Single refresh entry for toolbar, ⌘R, and legacy palette bindings.
    func performUnifiedRefresh(queueRefresh: () async -> Void) async {
        if refreshRoutingLyricsPresented {
            await unifiedRefreshMainSurface()
            return
        }
        if refreshRoutingQueuePanelVisible, refreshRoutingQueuePanelFocused {
            isUnifiedQueueRefreshActive = true
            defer { isUnifiedQueueRefreshActive = false }
            await queueRefresh()
            return
        }
        await unifiedRefreshMainSurface()
    }
}
