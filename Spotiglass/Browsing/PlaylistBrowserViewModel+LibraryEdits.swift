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
              let me = currentUserID, !me.isEmpty,
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
              let me = currentUserID, !me.isEmpty
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

    /// The rename request for an empty playlist: its page shows a message instead of its
    /// header, so the sidebar row takes it (#478). The window shows a hidden sidebar for it.
    var pendingSidebarPlaylistNameEditID: String? {
        guard let id = playlistNameEditRequestID,
              sidebarSelection == .playlist(id),
              case .empty = detailState
        else { return nil }
        return id
    }

    /// The same request once the sidebar shows, which is when its row can edit.
    var sidebarPlaylistNameEditRequestID: String? {
        isSidebarShown ? pendingSidebarPlaylistNameEditID : nil
    }

    func canDeletePlaylist(_ summary: MusicPlaylistSummary) -> Bool {
        guard supportedLibraryEdits.contains(.deletePlaylist),
              let me = currentUserID, !me.isEmpty
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

    // MARK: - Reorder (#543)

    /// True when the rows of `playlistID` can be dragged to a new spot: the provider can save a
    /// new order, and the playlist is the user's own or (Spotify) one they collaborate on.
    /// Liked Songs, albums and other people's playlists keep their order.
    func canReorderTracks(inPlaylist playlistID: String?) -> Bool {
        guard supportedLibraryEdits.contains(.reorderPlaylistTracks),
              let playlistID, playlistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              let me = currentUserID, !me.isEmpty,
              !playlistsRefusingReorder.contains(playlistID),
              let summary = playlistsByID[playlistID] ?? knownPlaylistSummariesByID[playlistID]
        else { return false }
        return summary.ownerID == me || summary.isCollaborative
    }

    /// Drops the rows `rowIDs` of the open playlist before the row at `offset` (a position in
    /// the list as shown; the row count drops them at the end), like the Spotify and Music
    /// apps: the list shows the new order at once, the service saves it, and a failed save puts
    /// the rows back with a one-line message. A drop while an earlier order is still saving
    /// does nothing.
    func moveTracks(rowIDs: [String], toOffset offset: Int, inPlaylist playlistID: String) async {
        guard reorderingPlaylistID == nil,
              canReorderTracks(inPlaylist: playlistID),
              let detail = shownPlaylistDetail(playlistID)
        else { return }
        let shown = detail.tracks
        // A long list shows its first rows a moment before the rest; an order counted in those
        // would leave the rest out.
        if let complete = completeRowsOnScreen, complete.playlistID == playlistID, complete.tracks.count > shown.count { return }
        let positions = Set(rowIDs.compactMap { id in shown.firstIndex { $0.id == id } })
        guard !positions.isEmpty else { return }
        let order = PlaylistTrackReorder.order(count: shown.count, moving: positions, toOffset: offset)
        guard !PlaylistTrackReorder.isUnchanged(order) else { return }
        let reordered = Self.rows(shown, in: order)
        showReorderedTracks(reordered, playlistID: playlistID)
        reorderingPlaylistID = playlistID
        defer { reorderingPlaylistID = nil }
        guard await ensureEditAllowed(.reorderPlaylist) else {
            await putBack(shown, replacing: reordered, playlistID: playlistID)
            return
        }
        do {
            // Positions count in the rows on screen, so the snapshot is the one they were read
            // at, not the sidebar's: a library refresh may have learned a newer one meanwhile.
            let newSnapshotID = try await api.reorderPlaylistTracks(
                playlistID: playlistID,
                reorder: MusicPlaylistReorder(order: order, currentTrackIDs: shown.map(\.spotifyTrackID)),
                snapshotID: detail.playlist.snapshotID
            )
            // A read that started before this point lists the old order: it must not replace the
            // new one now that the service has it.
            reorderGenerationByPlaylistID[playlistID, default: 0] += 1
            invalidateTracksCache(playlistID: playlistID)
            if let newSnapshotID { recordSnapshotID(newSnapshotID, playlistID: playlistID) }
            playlistsWithReadLeftOut.remove(playlistID)
            // Something else replaced the rows meanwhile: they are read again, in place.
            if let now = shownPlaylistTracks(playlistID), now != reordered {
                await showServiceOrder(playlistID: playlistID)
            }
        } catch let partial as MusicPlaylistReorderPartialFailure {
            reorderGenerationByPlaylistID[playlistID, default: 0] += 1
            // Spotify took the first requests of the order and not the rest: the screen shows
            // the order the playlist has now, under the snapshot those requests returned, so
            // the next edit counts from it.
            invalidateTracksCache(playlistID: playlistID)
            if let snapshotID = partial.snapshotID { recordSnapshotID(snapshotID, playlistID: playlistID) }
            playlistsWithReadLeftOut.remove(playlistID)
            if shownPlaylistTracks(playlistID) == reordered {
                showReorderedTracks(Self.rows(shown, in: partial.orderSoFar), playlistID: playlistID)
            } else {
                await showServiceOrder(playlistID: playlistID)
            }
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.reorderPartlySaved",
                Self.describeFailure(partial.underlying, operation: .reorderPlaylist)
            )
        } catch {
            await putBack(shown, replacing: reordered, playlistID: playlistID)
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.reorderFailed",
                (error as? MusicPlaylistChangedElsewhere)?.localizedDescription
                    ?? Self.describeFailure(error, operation: .reorderPlaylist)
            )
            // Apple Music's smart playlists can't be reordered, and nothing says so before
            // Music refuses: the playlist stops offering dragging after the first try.
            if error as? AppleMusicLibraryEditError == .notEditable {
                playlistsRefusingReorder.insert(playlistID)
            }
            // A failed save may still have changed the playlist (a reply lost after Spotify applied
            // it, Music stopping partway through its moves), both services refuse a playlist that
            // changed elsewhere since it was opened, and a read left out while this save ran may
            // have found changes: the list is read again, in place, so the screen and every later
            // drag count from the service's order. Offline the read fails and the rows stay back.
            playlistsWithReadLeftOut.remove(playlistID)
            await showServiceOrder(playlistID: playlistID)
        }
    }

    /// `rows` put in `order` (`order[i]` = the current position of the row that goes to `i`),
    /// numbered anew with the same row IDs.
    private static func rows(_ rows: [TrackRowViewModel], in order: [Int]) -> [TrackRowViewModel] {
        order.enumerated().map { rows[$0.element].at(listPosition: $0.offset + 1) }
    }

    /// The open playlist, when `playlistID` is the playlist on screen.
    private func shownPlaylistDetail(_ playlistID: String) -> PlaylistDetailViewModel? {
        guard case let .playlist(detail)? = detailState.currentValue, detail.playlist.id == playlistID else { return nil }
        return detail
    }

    /// The open playlist's rows, when `playlistID` is the playlist on screen.
    private func shownPlaylistTracks(_ playlistID: String) -> [TrackRowViewModel]? {
        shownPlaylistDetail(playlistID)?.tracks
    }

    private func showReorderedTracks(_ tracks: [TrackRowViewModel], playlistID: String, snapshotID: String? = nil) {
        guard let detail = shownPlaylistDetail(playlistID) else { return }
        let playlist = snapshotID.map { detail.playlist.at(snapshotID: $0) } ?? detail.playlist
        let content = BrowsingDetailContent.playlist(PlaylistDetailViewModel(playlist: playlist, tracks: tracks))
        switch detailState {
        case .loaded: detailState = .loaded(content)
        case .refreshing: detailState = .refreshing(content)
        case let .staleCache(_, error): detailState = .staleCache(content, error)
        case .loading, .empty, .error: return
        }
        if completeRowsOnScreen?.playlistID == playlistID {
            completeRowsOnScreen?.tracks = tracks
        }
    }

    /// After a failed save: the old order goes back when the screen still shows the new one;
    /// rows something else put there meanwhile are read once more, in place.
    private func putBack(_ previous: [TrackRowViewModel], replacing reordered: [TrackRowViewModel], playlistID: String) async {
        guard let now = shownPlaylistTracks(playlistID) else { return }
        if now == reordered {
            showReorderedTracks(previous, playlistID: playlistID)
        } else {
            await showServiceOrder(playlistID: playlistID)
        }
    }

    /// Reads the playlist again and shows the service's order in place of the rows on screen,
    /// without a loading state in between (the list doesn't blank or lose its scroll spot): rows
    /// the service still lists the same way keep their identity. Rows that changed on screen while
    /// it read are left as they are.
    private func showServiceOrder(playlistID: String) async {
        guard let shown = shownPlaylistTracks(playlistID),
              let items = try? await api.playlistTracks(playlistID: playlistID, limit: 50, maxPages: 200),
              !items.isEmpty,
              shownPlaylistTracks(playlistID) == shown
        else { return }
        invalidateTracksCache(playlistID: playlistID)
        let rows = TrackRowViewModel.numberedPlaylistRows(items)
        if rows != shown { showReorderedTracks(rows, playlistID: playlistID) }
    }

    /// Spotify's new snapshot after a reorder, so the next edit and the track cache name the
    /// playlist as it is now.
    private func recordSnapshotID(_ snapshotID: String, playlistID: String) {
        func updated(_ summary: MusicPlaylistSummary) -> MusicPlaylistSummary {
            MusicPlaylistSummary(
                id: summary.id,
                name: summary.name,
                ownerID: summary.ownerID,
                ownerName: summary.ownerName,
                imageURL: summary.imageURL,
                trackCount: summary.trackCount,
                snapshotID: snapshotID,
                isCollaborative: summary.isCollaborative
            )
        }
        if let summary = playlistsByID[playlistID] {
            playlistsByID[playlistID] = updated(summary)
            try? cache.savePlaylists(playlistsInSidebarOrder(), cachedAt: now())
        }
        if let summary = knownPlaylistSummariesByID[playlistID] {
            knownPlaylistSummariesByID[playlistID] = updated(summary)
        }
        // The open playlist's rows are in the new order now; the next drop counts from them.
        if let detail = shownPlaylistDetail(playlistID) {
            showReorderedTracks(detail.tracks, playlistID: playlistID, snapshotID: snapshotID)
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
            snapshotID: summary.snapshotID,
            isCollaborative: summary.isCollaborative
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
