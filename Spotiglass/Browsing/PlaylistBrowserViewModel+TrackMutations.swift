import Foundation

enum PlaylistMutationOperation: Equatable {
    case generic
    case addToPlaylist
    case moveBetweenPlaylists
    case addToLikedSongs
    case removeFromLikedSongs
    case createPlaylist
    case renamePlaylist
}

extension PlaylistBrowserViewModel {
    /// Track IDs the menu actions should apply to: the active table selection,
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

    /// Rows for the current table selection, in list order.
    ///
    /// The context menu uses ``effectiveTrackTargets(forRowID:)`` because it has
    /// a row to fall back on. A menu bar item has no row, only the selection, so
    /// an empty selection means there is nothing to act on (#132).
    var selectedTrackRows: [TrackRowViewModel] {
        let selection = selectedDetailTrackIDs
        guard !selection.isEmpty,
              let tracks = loadedContextTracksForPalette,
              !tracks.isEmpty else { return [] }
        return tracks.filter { selection.contains($0.id) }
    }

    /// Spotify catalog URIs (`spotify:track:...`) for playlist-mutation calls. Skips
    /// rows without a playable catalog URI (episodes, local files, unavailable).
    func playableURIs(for rows: [TrackRowViewModel]) -> [String] {
        rows.compactMap(\.playableURI).filter { $0.hasPrefix("spotify:track:") }
    }

    /// Unique catalog IDs (`spotify:track:<id>` → `<id>`) for Liked Songs
    /// save/remove calls. The Spotify endpoint treats IDs as a set.
    func catalogTrackIDs(for rows: [TrackRowViewModel]) -> [String] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let uri = row.playableURI, uri.hasPrefix("spotify:track:") else { return nil }
            let id = String(uri.dropFirst("spotify:track:".count))
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Rows accepted by playlist Add and Move operations.
    func playlistMutationRows(for rows: [TrackRowViewModel]) -> [TrackRowViewModel] {
        rows.filter { !playableURIs(for: [$0]).isEmpty }
    }

    /// Unique rows accepted by Liked Songs save and remove operations.
    func likedSongsMutationRows(for rows: [TrackRowViewModel]) -> [TrackRowViewModel] {
        var seen: Set<String> = []
        return rows.filter { row in
            guard let uri = row.playableURI, uri.hasPrefix("spotify:track:") else { return false }
            let id = String(uri.dropFirst("spotify:track:".count))
            return !id.isEmpty && seen.insert(id).inserted
        }
    }

    /// Returns the cached saved state for a catalog track, if the menu has
    /// already resolved it with `/v1/me/tracks/contains`.
    func savedTrackState(for id: String) -> Bool? {
        savedTrackStates[id]
    }

    /// Resolves the missing saved states for a menu's catalog rows. The Liked
    /// Songs surface skips this entirely because membership is known locally.
    func loadSavedTrackStates(for rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        let missing = ids.filter { savedTrackStates[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            let statuses = try await api.savedTrackStatuses(ids: missing)
            guard !Task.isCancelled, statuses.count == missing.count else { return }
            for (id, status) in zip(missing, statuses) {
                savedTrackStates[id] = status
            }
        } catch is CancellationError {
            return
        } catch {
            // Leave an unresolved row unavailable rather than guessing and
            // offering the wrong mutation.
        }
    }

    /// Exact source playlist positions for a row-level Move operation. Duplicate
    /// catalog tracks stay grouped by URI while retaining every selected slot.
    func playlistTrackRemovals(for rows: [TrackRowViewModel]) -> [SpotifyPlaylistTrackRemoval] {
        var order: [String] = []
        var positionsByURI: [String: [Int]] = [:]
        for row in rows {
            guard let uri = row.playableURI,
                  uri.hasPrefix("spotify:track:"),
                  row.listPosition > 0 else { continue }
            if positionsByURI[uri] == nil {
                order.append(uri)
            }
            positionsByURI[uri, default: []].append(row.listPosition - 1)
        }
        return order.compactMap { uri in
            guard let positions = positionsByURI[uri], !positions.isEmpty else { return nil }
            return SpotifyPlaylistTrackRemoval(uri: uri, positions: positions)
        }
    }

    // MARK: - Selection

    /// Called when the detail surface changes. The `List` binding owns every
    /// other write to the selection.
    func clearTrackSelection() {
        selectedDetailTrackIDs = []
    }

    // MARK: - Spotify Web API round-trips

    func addRowsToPlaylist(_ rows: [TrackRowViewModel], playlistID: String, playlistName: String) async {
        let uris = playableURIs(for: rows)
        guard !uris.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.noEligibleTracks")
            return
        }
        guard !playlistID.isEmpty else { return }
        guard await ensureScope(
            SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes),
            operation: .addToPlaylist
        ) else { return }
        do {
            try await api.addTracksToPlaylist(playlistID: playlistID, uris: uris)
            invalidateTracksCache(playlistID: playlistID)
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.addedToPlaylist",
                Int64(uris.count),
                playlistName
            )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .addToPlaylist)
        }
    }

    func moveRowsBetweenPlaylists(
        _ rows: [TrackRowViewModel],
        from sourcePlaylistID: String,
        to destinationPlaylistID: String,
        destinationName: String
    ) async {
        let uris = playableURIs(for: rows)
        let removals = playlistTrackRemovals(for: rows)
        let sourceIsLikedSongs = sourcePlaylistID == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        guard !uris.isEmpty,
              sourceIsLikedSongs || !removals.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.noEligibleTracks")
            return
        }
        guard !destinationPlaylistID.isEmpty else { return }
        guard await ensureScope(
            SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes),
            operation: .moveBetweenPlaylists
        ) else { return }

        do {
            try await api.addTracksToPlaylist(playlistID: destinationPlaylistID, uris: uris)
            if !sourcePlaylistID.isEmpty, !sourceIsLikedSongs {
                let snapshotID = playlistsByID[sourcePlaylistID]?.snapshotID
                    ?? knownPlaylistSummariesByID[sourcePlaylistID]?.snapshotID
                do {
                    try await api.removeTracksFromPlaylist(
                        playlistID: sourcePlaylistID,
                        items: removals,
                        snapshotID: snapshotID
                    )
                } catch {
                    invalidateTracksCache(playlistID: sourcePlaylistID)
                    invalidateTracksCache(playlistID: destinationPlaylistID)
                    await refreshCurrentPlaylistMutationDetail(
                        for: [sourcePlaylistID, destinationPlaylistID]
                    )
                    trackMutationToast = Self.isScopeFailure(error)
                        ? Self.describeFailure(error, operation: .moveBetweenPlaylists)
                        : SpotiglassL10n.format(
                            "playlist.mutation.partialMove",
                            destinationName
                        )
                    return
                }
                invalidateTracksCache(playlistID: sourcePlaylistID)
            }
            invalidateTracksCache(playlistID: destinationPlaylistID)
            await refreshCurrentPlaylistMutationDetail(
                for: [sourcePlaylistID, destinationPlaylistID]
            )
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.movedToPlaylist",
                Int64(uris.count),
                destinationName
            )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .moveBetweenPlaylists)
        }
    }

    func favoriteRows(_ rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.noEligibleTracks")
            return
        }
        guard await ensureScope(
            SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredSavedTracksModifyScopes),
            operation: .addToLikedSongs
        ) else { return }
        do {
            try await api.saveTracks(ids: ids)
            for id in ids {
                savedTrackStates[id] = true
            }
            invalidateLikedSongsCache()
            await refreshLikedSongsDetailAfterMutation()
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.addedToLikedSongs",
                Int64(ids.count)
            )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .addToLikedSongs)
        }
    }

    func unfavoriteRows(_ rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.noEligibleTracks")
            return
        }
        guard await ensureScope(
            SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredSavedTracksModifyScopes),
            operation: .removeFromLikedSongs
        ) else { return }
        do {
            try await api.removeSavedTracks(ids: ids)
            for id in ids {
                savedTrackStates[id] = false
            }
            invalidateLikedSongsCache()
            await refreshLikedSongsDetailAfterMutation()
            trackMutationToast = SpotiglassL10n.format(
                "playlist.mutation.removedFromLikedSongs",
                Int64(ids.count)
            )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .removeFromLikedSongs)
        }
    }

    /// Creates a new playlist under the signed-in user's account and adds
    /// `rows` to it. The created summary is inserted at the top of the
    /// sidebar so the user immediately sees it.
    func createPlaylistWithRows(name: String, rows: [TrackRowViewModel]) async {
        guard let userID = currentUserSpotifyID, !userID.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("playlist.mutation.signInToCreate")
            return
        }
        guard await ensureScope(
            SpotifyScopeRequirement(allOf: [SpotifyAuthConfiguration.requiredPlaylistModifyScopes[0]]),
            operation: .createPlaylist
        ) else { return }
        do {
            let created = try await api.createPlaylist(userID: userID, name: name, isPublic: false)
            let uris = playableURIs(for: rows)
            if !uris.isEmpty {
                try await api.addTracksToPlaylist(playlistID: created.id, uris: uris)
            }
            insertSidebarPlaylist(created, refreshedTrackCount: uris.count)
            trackMutationToast = uris.isEmpty
                ? SpotiglassL10n.format("playlist.mutation.createdPlaylist", created.name)
                : SpotiglassL10n.format(
                    "playlist.mutation.createdPlaylistWithTracks",
                    created.name,
                    Int64(uris.count)
                )
        } catch {
            trackMutationToast = Self.describeFailure(error, operation: .createPlaylist)
        }
    }

    /// Renames an owned playlist and updates the sidebar and detail surfaces before
    /// the Spotify request completes. A failed request restores the previous name.
    func renamePlaylist(id: String, name: String) async {
        guard let previous = playlistsByID[id] else { return }
        guard let currentUserID = currentUserSpotifyID,
              !currentUserID.isEmpty,
              previous.ownerID == currentUserID
        else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != previous.name else { return }

        let renamed = SpotifyPlaylistSummary(
            id: previous.id,
            name: trimmedName,
            ownerID: previous.ownerID,
            ownerName: previous.ownerName,
            imageURL: previous.imageURL,
            trackCount: previous.trackCount,
            snapshotID: previous.snapshotID
        )
        applyPlaylistName(renamed)

        guard await ensureScope(
            SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes),
            operation: .renamePlaylist
        ) else {
            applyPlaylistName(previous)
            return
        }

        do {
            try await api.updatePlaylist(playlistID: id, name: trimmedName)
        } catch {
            applyPlaylistName(previous)
            trackMutationToast = Self.describeFailure(error, operation: .renamePlaylist)
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

    /// Stops a known-missing capability before an API implementation can issue
    /// the request. This is intentionally a redirecting toast rather than a
    /// silent no-op so the existing Settings ▸ Account ▸ Reconnect path is
    /// discoverable.
    private func ensureScope(
        _ requirement: SpotifyScopeRequirement,
        operation: PlaylistMutationOperation
    ) async -> Bool {
        guard let scopeProvider, !requirement.isEmpty else { return true }
        let granted = await scopeProvider.grantedScopes()
        let missing = requirement.missingScopes(from: granted)
        guard !missing.isEmpty else { return true }

        let error = SpotifyAPIError.insufficientScope(
            requiredScopes: missing,
            message: nil,
            details: "Scope preflight denied a playlist mutation: missing \(missing.joined(separator: ", "))."
        )
        trackMutationToast = Self.describeFailure(error, operation: operation)
        return false
    }

    /// Converts a mutation failure into user copy without leaking Spotify's
    /// generic 403 reason phrase. The operation-specific variants name the
    /// capability and point at the existing reconnect control.
    static func describeFailure(_ error: Error, operation: PlaylistMutationOperation = .generic) -> String {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .insufficientScope, .forbidden:
                switch operation {
                case .addToLikedSongs, .removeFromLikedSongs:
                    return SpotiglassL10n.string("playlist.mutation.likedSongsRequiresReconnect")
                case .addToPlaylist, .moveBetweenPlaylists, .createPlaylist, .renamePlaylist:
                    return SpotiglassL10n.string("playlist.mutation.playlistRequiresReconnect")
                case .generic:
                    break
                }
            default:
                break
            }
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }

    private static func isScopeFailure(_ error: Error) -> Bool {
        guard let apiError = error as? SpotifyAPIError else { return false }
        return switch apiError {
        case .insufficientScope, .forbidden:
            true
        default:
            false
        }
    }

    private func applyPlaylistName(_ playlist: SpotifyPlaylistSummary) {
        playlistsByID[playlist.id] = playlist

        if let rows = playlistState.currentValue {
            let renamedRows = rows.map { row in
                row.id == playlist.id ? PlaylistRowViewModel(playlist) : row
            }
            switch playlistState {
            case .loading, .empty, .error:
                break
            case .loaded:
                playlistState = .loaded(renamedRows)
            case .refreshing:
                playlistState = .refreshing(renamedRows)
            case let .staleCache(_, displayError):
                playlistState = .staleCache(renamedRows, displayError)
            }
        }

        if let content = detailState.currentValue,
           case let .playlist(detail) = content,
           detail.playlist.id == playlist.id {
            let renamedDetail = PlaylistDetailViewModel(
                playlist: PlaylistRowViewModel(playlist),
                tracks: detail.tracks
            )
            switch detailState {
            case .loading, .empty, .error:
                break
            case .loaded:
                detailState = .loaded(.playlist(renamedDetail))
            case .refreshing:
                detailState = .refreshing(.playlist(renamedDetail))
            case let .staleCache(_, displayError):
                detailState = .staleCache(.playlist(renamedDetail), displayError)
            }
        }

        try? cache.savePlaylists(Array(playlistsByID.values), cachedAt: now())
    }

    private func invalidateTracksCache(playlistID: String) {
        guard !playlistID.isEmpty else { return }
        try? cache.invalidateTracks(playlistID: playlistID)
        invalidateLibraryContinuationCache()
        lastTracksRevalidationByID.removeValue(forKey: playlistID)
        if playlistID == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            likedSongsMutationGeneration += 1
            likedSongsRevalidationTask?.cancel()
            likedSongsRevalidationTask = nil
            likedSongsRevalidationTaskGeneration = nil
            lastLikedSongsRevalidationAt = nil
        }
    }

    private func invalidateLikedSongsCache() {
        invalidateTracksCache(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
    }

    private func refreshLikedSongsDetailAfterMutation() async {
        guard sidebarSelection == .likedSongs else { return }
        await revalidateLikedSongs(session: detailSession)
    }

    private func refreshCurrentPlaylistMutationDetail(for playlistIDs: [String]) async {
        guard case let .playlist(currentPlaylistID) = sidebarSelection,
              playlistIDs.contains(currentPlaylistID),
              currentPlaylistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              playlistsByID[currentPlaylistID] != nil || knownPlaylistSummariesByID[currentPlaylistID] != nil
        else { return }
        await loadTracks(for: currentPlaylistID, refreshCachedData: true, session: detailSession)
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
        invalidateLibraryContinuationCache()
    }
}
