import Foundation

/// A removal from the library that waits for the user's confirmation.
enum PendingLibraryRemoval {
    /// Rows to take out of Liked Songs.
    case songs([TrackRowViewModel])
    case album(id: String, name: String)
}

/// Library edits only some providers offer (`MusicLibraryEdits`): removing songs from a
/// playlist, deleting a playlist and saving albums. The menus offer them only when
/// `supportedLibraryEdits` says so, so Spotify's menus stay as they are.
extension PlaylistBrowserViewModel {
    var supportedLibraryEdits: MusicLibraryEdits {
        api.supportedLibraryEdits
    }

    /// True when `playlistID` is one of the signed-in user's own playlists.
    func isUserOwnedPlaylist(_ playlistID: String?) -> Bool {
        guard let playlistID, playlistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              let me = currentUserSpotifyID, !me.isEmpty,
              let summary = playlistsByID[playlistID] ?? knownPlaylistSummariesByID[playlistID]
        else { return false }
        return summary.ownerID == me
    }

    func canRemoveRows(fromPlaylist playlistID: String?) -> Bool {
        supportedLibraryEdits.contains(.removeFromPlaylist) && isUserOwnedPlaylist(playlistID)
    }

    /// The user's own playlists can be renamed; Liked Songs and other people's can't. A playlist
    /// the library hasn't loaded yet (made in another app, found through Search) can't either:
    /// renaming goes through the library's copy (`renamePlaylist`).
    func canRenamePlaylist(_ summary: MusicPlaylistSummary) -> Bool {
        guard summary.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              playlistsByID[summary.id] != nil,
              let me = currentUserSpotifyID, !me.isEmpty
        else { return false }
        return summary.ownerID == me
    }

    /// "Edit playlist name" from a tile or card outside the sidebar (Home, Search): opens the
    /// playlist, and its header starts editing the name once it shows (#478).
    func openPlaylistForNameEditing(_ summary: MusicPlaylistSummary) async {
        guard canRenamePlaylist(summary) else { return }
        playlistNameEditRequestID = summary.id
        await selectPlaylist(summary: summary, origin: .extend)
        // The header takes the request once the playlist shows, and an empty playlist (no
        // header) leaves it to its sidebar row (``sidebarPlaylistNameEditRequestID``). When the
        // playlist didn't open (it failed to load, or the user went elsewhere first) the request
        // goes, or opening that playlist later would start editing its name out of nowhere.
        guard playlistNameEditRequestID == summary.id else { return }
        if sidebarSelection == .playlist(summary.id) {
            if case let .playlist(detail)? = detailState.currentValue, detail.playlist.id == summary.id { return }
            if case .empty = detailState { return }
        }
        playlistNameEditRequestID = nil
    }

    /// The rename request the sidebar row takes: an empty playlist shows a message instead of
    /// its header, so the header can't (#478).
    var sidebarPlaylistNameEditRequestID: String? {
        guard let id = playlistNameEditRequestID,
              sidebarSelection == .playlist(id),
              case .empty = detailState
        else { return nil }
        return id
    }

    func canDeletePlaylist(_ summary: MusicPlaylistSummary) -> Bool {
        guard supportedLibraryEdits.contains(.deletePlaylist),
              let me = currentUserSpotifyID, !me.isEmpty
        else { return false }
        return summary.ownerID == me && summary.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    // MARK: - Remove from playlist

    func removeRowsFromPlaylist(_ rows: [TrackRowViewModel], playlistID: String, playlistName: String) async {
        let removals = playlistTrackRemovals(for: rows)
        guard !removals.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.noEligibleTracks")
            return
        }
        let count = removals.reduce(0) { $0 + $1.positions.count }
        do {
            try await api.removeTracksFromPlaylist(
                playlistID: playlistID,
                items: removals,
                snapshotID: playlistsByID[playlistID]?.snapshotID
            )
            invalidateTracksCache(playlistID: playlistID)
            selectedDetailTrackIDs = []
            adjustSidebarTrackCountAfterEdit(playlistID: playlistID, by: -count)
            await refreshCurrentPlaylistMutationDetail(for: [playlistID])
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.removedFromPlaylist",
                Int64(count),
                playlistName
            )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .removeFromPlaylist)
        }
    }

    // MARK: - Delete playlist

    /// Shows the confirmation; `deletePlaylist(_:)` does the work once the user confirms.
    func requestPlaylistDeletion(_ summary: MusicPlaylistSummary) {
        guard canDeletePlaylist(summary) else { return }
        playlistPendingDeletion = summary
    }

    func deletePlaylist(_ summary: MusicPlaylistSummary) async {
        playlistPendingDeletion = nil
        guard canDeletePlaylist(summary) else { return }
        do {
            try await api.deletePlaylist(playlistID: summary.id)
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .deletePlaylist)
            return
        }
        removeSidebarPlaylist(id: summary.id)
        if sidebarSelection == .playlist(summary.id) {
            await selectSidebar(.home)
        }
        forgetDeletedPlaylist(id: summary.id)
        trackMutationToast = SpotiglassL10n.format("playlist.mutation.deletedPlaylist", summary.name)
    }

    /// Keeps the sidebar's "N tracks" in step with an edit, instead of the count the playlist
    /// had when the list was loaded (#395). Only for providers with their own playlist edits
    /// (Apple Music); Spotify's counts stay as they were, refreshed with the next playlist load.
    func adjustSidebarTrackCountAfterEdit(playlistID: String, by delta: Int) {
        guard supportedLibraryEdits.contains(.removeFromPlaylist), delta != 0 else { return }
        // A count run that was already reading the library may have the count from before the
        // edit, or one that already has it: either way the playlist is counted again with the
        // edit, and that count replaces this quick one.
        playlistTrackCountEdits[playlistID, default: 0] += 1
        countPlaylistTracks(of: playlistID)
        guard let summary = playlistsByID[playlistID], let count = summary.trackCount else { return }
        let adjusted = MusicPlaylistSummary(
            id: summary.id,
            name: summary.name,
            ownerID: summary.ownerID,
            ownerName: summary.ownerName,
            imageURL: summary.imageURL,
            trackCount: max(0, count + delta),
            snapshotID: summary.snapshotID
        )
        playlistsByID[playlistID] = adjusted
        guard let rows = playlistState.currentValue else { return }
        let updated = rows.map { $0.id == playlistID ? PlaylistRowViewModel(adjusted) : $0 }
        switch playlistState {
        case .loading, .empty, .error:
            break
        case .loaded:
            playlistState = .loaded(updated)
        case .refreshing:
            playlistState = .refreshing(updated)
        case let .staleCache(_, displayError):
            playlistState = .staleCache(updated, displayError)
        }
        try? cache.savePlaylists(playlistsInSidebarOrder(), cachedAt: now())
    }

    private func removeSidebarPlaylist(id: String) {
        playlistsByID[id] = nil
        knownPlaylistSummariesByID[id] = nil
        invalidateTracksCache(playlistID: id)
        guard let rows = playlistState.currentValue else { return }
        let remaining = rows.filter { $0.id != id }
        switch playlistState {
        case .loading, .empty, .error:
            break
        case .loaded:
            playlistState = remaining.isEmpty
                ? .empty(SpotiglassL10n.format("browser.empty.noPlaylists", MusicServiceSelection.current.displayName))
                : .loaded(remaining)
        case .refreshing:
            playlistState = .refreshing(remaining)
        case let .staleCache(_, displayError):
            playlistState = .staleCache(remaining, displayError)
        }
        try? cache.savePlaylists(playlistsInSidebarOrder(), cachedAt: now())
    }

    // MARK: - Albums

    func savedAlbumState(for albumID: String) -> Bool? {
        savedAlbumStates[albumID]
    }

    func loadSavedAlbumState(for albumID: String) async {
        guard supportedLibraryEdits.contains(.saveAlbums), !albumID.isEmpty, savedAlbumStates[albumID] == nil else { return }
        do {
            let statuses = try await api.savedAlbumStatuses(ids: [albumID])
            guard !Task.isCancelled, let status = statuses.first else { return }
            savedAlbumStates[albumID] = status
        } catch {
            // Unknown stays unknown; the menu item stays disabled rather than offering the wrong edit.
        }
    }

    /// Saves the album when it is not in the library, removes it when it is. The menu shows the
    /// new state at once and goes back if the edit fails.
    /// Removing asks first when the provider's removal also empties playlists
    /// (`MusicLibraryEdits.confirmLibraryRemoval`); the confirmation calls back with `confirmed`.
    func toggleAlbumInLibrary(albumID: String, albumName: String, confirmed: Bool = false) async {
        guard let isSaved = savedAlbumStates[albumID] else { return }
        if isSaved, !confirmed, supportedLibraryEdits.contains(.confirmLibraryRemoval) {
            pendingLibraryRemoval = .album(id: albumID, name: albumName)
            return
        }
        savedAlbumStates[albumID] = !isSaved
        do {
            if isSaved {
                try await api.removeSavedAlbums(ids: [albumID])
            } else {
                try await api.saveAlbums(ids: [albumID])
            }
            // The album's songs changed too; their liked state loads again when a menu needs it.
            savedTrackStates = [:]
            invalidateLikedSongsCache()
            if isSaved { recountPlaylistTracksAfterLibraryRemoval() }
            await refreshLikedSongsDetailAfterMutation()
            trackMutationToast = SpotiglassL10n.format(
                isSaved ? "playlist.mutation.removedAlbum" : "playlist.mutation.addedAlbum",
                albumName
            )
        } catch {
            savedAlbumStates[albumID] = isSaved
            trackMutationToast = Self.describeFailure(error, operation: .saveAlbum)
        }
    }

    // MARK: - Library removal confirmation

    /// Runs the removal the user just confirmed. The alert hands it over itself: dismissing the
    /// alert clears `pendingLibraryRemoval` before this task runs.
    func confirmLibraryRemoval(_ removal: PendingLibraryRemoval) async {
        pendingLibraryRemoval = nil
        switch removal {
        case let .songs(rows):
            await unfavoriteRows(rows, confirmed: true)
        case let .album(id, name):
            await toggleAlbumInLibrary(albumID: id, albumName: name, confirmed: true)
        }
    }
}
