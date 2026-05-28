import Foundation

extension PlaylistBrowserViewModel {
    /// Track IDs the menu actions should apply to: the active shift-click selection,
    /// or just the row the menu was opened on when no selection exists.
    func effectiveTrackTargets(forRowID rowID: String) -> [TrackRowViewModel] {
        guard let tracks = loadedContextTracksForPalette, !tracks.isEmpty else { return [] }
        let selection = selectedDetailTrackIDs
        if selection.contains(rowID), selection.count > 1 {
            // Preserve list order so batched calls keep playlist sequence sane.
            return tracks.filter { selection.contains($0.id) }
        }
        return tracks.first(where: { $0.id == rowID }).map { [$0] } ?? []
    }

    /// Spotify catalog URIs (`spotify:track:...`) for playlist-mutation calls. Skips
    /// rows without a playable catalog URI (episodes, local files, unavailable).
    func playableURIs(for rows: [TrackRowViewModel]) -> [String] {
        rows.compactMap(\.playableURI).filter { $0.hasPrefix("spotify:track:") }
    }

    /// Catalog IDs (`spotify:track:<id>` → `<id>`) for Liked Songs save/remove calls.
    func catalogTrackIDs(for rows: [TrackRowViewModel]) -> [String] {
        rows.compactMap { row in
            guard let uri = row.playableURI, uri.hasPrefix("spotify:track:") else { return nil }
            let id = String(uri.dropFirst("spotify:track:".count))
            return id.isEmpty ? nil : id
        }
    }

    // MARK: - Selection (shift-click range)

    /// Extends the selection from the previous anchor to `trackID`, inclusive,
    /// in track-list order. If there is no anchor yet, becomes a single
    /// selection of `trackID`. Sets the new anchor to `trackID`.
    func extendSelection(toRowID trackID: String) {
        guard let tracks = loadedContextTracksForPalette,
              let endIndex = tracks.firstIndex(where: { $0.id == trackID })
        else {
            selectedDetailTrackIDs = [trackID]
            detailSelectionAnchorTrackID = trackID
            return
        }
        let anchorID = detailSelectionAnchorTrackID ?? trackID
        let startIndex = tracks.firstIndex(where: { $0.id == anchorID }) ?? endIndex
        let (lo, hi) = startIndex <= endIndex ? (startIndex, endIndex) : (endIndex, startIndex)
        selectedDetailTrackIDs = Set(tracks[lo...hi].map(\.id))
        detailSelectionAnchorTrackID = trackID
    }

    /// Click without modifiers — replace selection so the row is "primary",
    /// and reset the anchor for a future shift-extend.
    func setPrimarySelection(trackID: String) {
        selectedDetailTrackIDs = [trackID]
        detailSelectionAnchorTrackID = trackID
    }

    func clearTrackSelection() {
        selectedDetailTrackIDs = []
        detailSelectionAnchorTrackID = nil
    }

    // MARK: - Spotify Web API round-trips

    func addRowsToPlaylist(_ rows: [TrackRowViewModel], playlistID: String, playlistName: String) async {
        let uris = playableURIs(for: rows)
        guard !uris.isEmpty, !playlistID.isEmpty else { return }
        do {
            try await api.addTracksToPlaylist(playlistID: playlistID, uris: uris)
            invalidateTracksCache(playlistID: playlistID)
            trackMutationToast = "Added \(uris.count) track\(uris.count == 1 ? "" : "s") to \(playlistName)"
        } catch {
            trackMutationToast = describeFailure(error)
        }
    }

    func moveRowsBetweenPlaylists(
        _ rows: [TrackRowViewModel],
        from sourcePlaylistID: String,
        to destinationPlaylistID: String,
        destinationName: String
    ) async {
        let uris = playableURIs(for: rows)
        guard !uris.isEmpty, !destinationPlaylistID.isEmpty else { return }
        do {
            try await api.addTracksToPlaylist(playlistID: destinationPlaylistID, uris: uris)
            if !sourcePlaylistID.isEmpty,
               sourcePlaylistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
                try await api.removeTracksFromPlaylist(playlistID: sourcePlaylistID, uris: uris)
                invalidateTracksCache(playlistID: sourcePlaylistID)
                // Reflect the removal locally so the UI doesn't show ghosts
                // until the next refresh round-trip completes.
                removeRowsFromLoadedDetail(rowIDs: Set(rows.map(\.id)))
            }
            invalidateTracksCache(playlistID: destinationPlaylistID)
            trackMutationToast = "Moved \(uris.count) track\(uris.count == 1 ? "" : "s") to \(destinationName)"
        } catch {
            trackMutationToast = describeFailure(error)
        }
    }

    func favoriteRows(_ rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else { return }
        do {
            try await api.saveTracks(ids: ids)
            trackMutationToast = "Added \(ids.count) track\(ids.count == 1 ? "" : "s") to Liked Songs"
        } catch {
            trackMutationToast = describeFailure(error)
        }
    }

    func unfavoriteRows(_ rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else { return }
        do {
            try await api.removeSavedTracks(ids: ids)
            trackMutationToast = "Removed \(ids.count) track\(ids.count == 1 ? "" : "s") from Liked Songs"
        } catch {
            trackMutationToast = describeFailure(error)
        }
    }

    /// Creates a new playlist under the signed-in user's account and adds
    /// `rows` to it. The created summary is inserted at the top of the
    /// sidebar so the user immediately sees it.
    func createPlaylistWithRows(name: String, rows: [TrackRowViewModel]) async {
        guard let userID = currentUserSpotifyID, !userID.isEmpty else {
            trackMutationToast = "Sign in to Spotify before creating a playlist."
            return
        }
        do {
            let created = try await api.createPlaylist(userID: userID, name: name, isPublic: false)
            let uris = playableURIs(for: rows)
            if !uris.isEmpty {
                try await api.addTracksToPlaylist(playlistID: created.id, uris: uris)
            }
            insertSidebarPlaylist(created, refreshedTrackCount: uris.count)
            trackMutationToast = uris.isEmpty
                ? "Created \(created.name)"
                : "Created \(created.name) with \(uris.count) track\(uris.count == 1 ? "" : "s")"
        } catch {
            trackMutationToast = describeFailure(error)
        }
    }

    /// User-owned playlists (excluding the virtual liked-songs row) for menu listing.
    func userOwnedPlaylistsForMenu(excludingPlaylistID excluding: String?) -> [SpotifyPlaylistSummary] {
        let me = currentUserSpotifyID ?? ""
        return playlistState.currentValue?.compactMap { row -> SpotifyPlaylistSummary? in
            guard let summary = playlistsByID[row.id], summary.ownerID == me else { return nil }
            if let excluding, summary.id == excluding { return nil }
            return summary
        } ?? []
    }

    // MARK: - Internal helpers

    private func describeFailure(_ error: Error) -> String {
        if let apiError = error as? SpotifyAPIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }

    private func invalidateTracksCache(playlistID: String) {
        guard playlistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              !playlistID.isEmpty else { return }
        try? cache.invalidateTracks(playlistID: playlistID)
        lastTracksRevalidationByID.removeValue(forKey: playlistID)
    }

    private func removeRowsFromLoadedDetail(rowIDs: Set<String>) {
        guard let content = detailState.currentValue,
              case let .playlist(playlistViewModel) = content
        else { return }
        let filtered = playlistViewModel.tracks.filter { !rowIDs.contains($0.id) }
        let renumbered = filtered.enumerated().map { idx, row -> TrackRowViewModel in
            TrackRowViewModel(
                id: row.id,
                listPosition: idx + 1,
                title: row.title,
                subtitle: row.subtitle,
                artworkURL: row.artworkURL,
                durationText: row.durationText,
                badgeText: row.badgeText,
                isUnavailable: row.isUnavailable,
                isExplicit: row.isExplicit,
                playableURI: row.playableURI,
                artistRefs: row.artistRefs
            )
        }
        let nextDetail = PlaylistDetailViewModel(playlist: playlistViewModel.playlist, tracks: renumbered)
        switch detailState {
        case .loading, .empty, .error:
            break
        case .loaded:
            detailState = .loaded(.playlist(nextDetail))
        case let .refreshing(_):
            detailState = .refreshing(.playlist(nextDetail))
        case let .staleCache(_, displayError):
            detailState = .staleCache(.playlist(nextDetail), displayError)
        }
        // Drop selection IDs that no longer exist.
        selectedDetailTrackIDs.subtract(rowIDs)
        if let anchor = detailSelectionAnchorTrackID, rowIDs.contains(anchor) {
            detailSelectionAnchorTrackID = nil
        }
    }

    private func insertSidebarPlaylist(_ summary: SpotifyPlaylistSummary, refreshedTrackCount: Int) {
        let normalised = SpotifyPlaylistSummary(
            id: summary.id,
            name: summary.name,
            ownerID: summary.ownerID,
            ownerName: summary.ownerName,
            imageURL: summary.imageURL,
            trackCount: refreshedTrackCount,
            snapshotID: summary.snapshotID
        )
        playlistsByID[summary.id] = normalised
        var rows = playlistState.currentValue ?? []
        if !rows.contains(where: { $0.id == summary.id }) {
            rows.insert(PlaylistRowViewModel(normalised), at: 0)
            switch playlistState {
            case .loading, .empty, .error:
                playlistState = .loaded(rows)
            case .loaded:
                playlistState = .loaded(rows)
            case .refreshing:
                playlistState = .refreshing(rows)
            case let .staleCache(_, displayError):
                playlistState = .staleCache(rows, displayError)
            }
        }
        try? cache.savePlaylists(Array(playlistsByID.values), cachedAt: now())
    }
}

private extension TrackRowViewModel {
    /// Memberwise builder used by `removeRowsFromLoadedDetail` to rebuild rows
    /// with updated `listPosition` after a destructive mutation.
    init(
        id: String,
        listPosition: Int,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        durationText: String,
        badgeText: String?,
        isUnavailable: Bool,
        isExplicit: Bool,
        playableURI: String?,
        artistRefs: [SpotifyArtistRef]
    ) {
        self.id = id
        self.listPosition = listPosition
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.durationText = durationText
        self.badgeText = badgeText
        self.isUnavailable = isUnavailable
        self.isExplicit = isExplicit
        self.playableURI = playableURI
        self.artistRefs = artistRefs
    }
}
