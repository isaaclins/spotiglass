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
        // A failed artist or album page reloads that page, like its Retry button (#465).
        if case .error = detailState {
            switch currentNavigationTarget {
            case .artist, .album:
                await retryFailedDetail()
                return
            case .sidebar, nil:
                break
            }
        }
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

    /// Retry on a page that failed to load: the artist or album it was opened for loads again.
    /// An album opened from Home or Search keeps that sidebar row selected, so the sidebar
    /// alone would reload Home or the search instead of the album (#465).
    func retryFailedDetail() async {
        switch currentNavigationTarget {
        case let .artist(id):
            await selectArtist(id: id, forceRefresh: true, origin: .backStackReplay, displayName: nil)
        case let .album(id, title, subtitle, artworkURL):
            await selectAlbum(
                id: id,
                displayTitle: title,
                displaySubtitle: subtitle,
                artworkURL: artworkURL,
                origin: .backStackReplay
            )
        case .sidebar, nil:
            await unifiedRefreshMainSurface()
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
