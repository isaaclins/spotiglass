import Foundation

enum PlaylistMutationOperation: Equatable {
    case generic
    case addToPlaylist
    case moveBetweenPlaylists
    case addToLikedSongs
    case removeFromLikedSongs
    case createPlaylist
    case renamePlaylist
    case removeFromPlaylist
    case deletePlaylist
    case saveAlbum
    case reorderPlaylist
}

/// Track URIs a provider can put into playlists and Liked Songs: Spotify catalog tracks and
/// Apple Music songs. Episodes, local files and unavailable rows have neither.
enum LibraryEditableTrackURI {
    static let prefixes = ["spotify:track:", "applemusic:song:"]

    static func isEditable(_ uri: String?) -> Bool {
        trackID(uri) != nil
    }

    /// The track ID after the prefix, or `nil` for any other URI.
    static func trackID(_ uri: String?) -> String? {
        guard let uri, let prefix = prefixes.first(where: { uri.hasPrefix($0) }) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
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

    /// Track URIs (`spotify:track:...`, `applemusic:song:...`) for playlist-mutation calls. Skips
    /// rows without a playable catalog URI (episodes, local files, unavailable).
    func playableURIs(for rows: [TrackRowViewModel]) -> [String] {
        rows.compactMap(\.playableURI).filter(LibraryEditableTrackURI.isEditable)
    }

    /// Unique catalog IDs (`spotify:track:<id>` → `<id>`) for Liked Songs
    /// save/remove calls. The Spotify endpoint treats IDs as a set.
    func catalogTrackIDs(for rows: [TrackRowViewModel]) -> [String] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let id = LibraryEditableTrackURI.trackID(row.playableURI), seen.insert(id).inserted else { return nil }
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
            guard let id = LibraryEditableTrackURI.trackID(row.playableURI) else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Returns the cached saved state for a catalog track, if the menu has
    /// already resolved it with `/v1/me/tracks/contains`.
    func savedTrackState(for id: String) -> Bool? {
        // A provider may know it before any request (#395: an Apple Music library song read as
        // unknown until the lookup came back, so the menu showed a disabled "Add").
        savedTrackStates[id] ?? api.knownSavedTrackStatus(id: id)
    }

    /// A provider can know one song under several IDs (Apple Music: a playlist row's persistent
    /// ID, search's catalog ID). After a like or unlike, a cached answer the provider now answers
    /// differently is for another ID of the same song, so it goes and the row reads the
    /// provider's answer. Spotify answers nothing here, so its cache stays as it was.
    private func dropSavedTrackStatesTheProviderNowAnswers() {
        for (id, cached) in savedTrackStates {
            if let known = api.knownSavedTrackStatus(id: id), known != cached {
                savedTrackStates[id] = nil
            }
        }
    }

    /// Resolves the missing saved states for a menu's catalog rows. The Liked
    /// Songs surface skips this entirely because membership is known locally.
    func loadSavedTrackStates(for rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        // A cached answer the provider now answers differently is out of date (an album saved
        // meanwhile, a row read again): this menu asks again.
        for id in ids {
            if let cached = savedTrackStates[id], let known = api.knownSavedTrackStatus(id: id), known != cached {
                savedTrackStates[id] = nil
            }
        }
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
    func playlistTrackRemovals(for rows: [TrackRowViewModel]) -> [MusicPlaylistTrackRemoval] {
        var order: [String] = []
        var positionsByURI: [String: [Int]] = [:]
        for row in rows {
            guard let uri = row.playableURI,
                  LibraryEditableTrackURI.isEditable(uri),
                  row.listPosition > 0 else { continue }
            if positionsByURI[uri] == nil {
                order.append(uri)
            }
            positionsByURI[uri, default: []].append(row.listPosition - 1)
        }
        return order.compactMap { uri in
            guard let positions = positionsByURI[uri], !positions.isEmpty else { return nil }
            return MusicPlaylistTrackRemoval(uri: uri, positions: positions)
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
            trackMutationToastText = LocalizedText(SpotiglassL10n.string("playlist.mutation.noEligibleTracks"))
            return
        }
        guard !playlistID.isEmpty else { return }
        guard await ensureEditAllowed(.addToPlaylist) else { return }
        do {
            try await api.addTracksToPlaylist(playlistID: playlistID, uris: uris)
            invalidateTracksCache(playlistID: playlistID)
            adjustSidebarTrackCountAfterEdit(playlistID: playlistID, by: uris.count)
            trackMutationToastText = LocalizedText(SpotiglassL10n.format(
                "playlist.mutation.addedToPlaylist",
                Int64(uris.count),
                playlistName
            ))
        } catch {
            trackMutationToastText = Self.failureText(error, operation: .addToPlaylist)
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
            trackMutationToastText = LocalizedText(SpotiglassL10n.string("playlist.mutation.noEligibleTracks"))
            return
        }
        guard !destinationPlaylistID.isEmpty else { return }
        guard await ensureEditAllowed(.moveBetweenPlaylists) else { return }

        do {
            try await api.addTracksToPlaylist(playlistID: destinationPlaylistID, uris: uris)
            // The songs are in the destination now, even if taking them out of the source fails.
            adjustSidebarTrackCountAfterEdit(playlistID: destinationPlaylistID, by: uris.count)
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
                    let service = MusicServiceSelection.current
                    trackMutationToastText = LocalizedText(Self.isScopeFailure(error)
                        ? Self.describeFailure(error, operation: .moveBetweenPlaylists, service: service)
                        : SpotiglassL10n.format(
                            "playlist.mutation.partialMove",
                            destinationName
                        ))
                    return
                }
                invalidateTracksCache(playlistID: sourcePlaylistID)
                adjustSidebarTrackCountAfterEdit(
                    playlistID: sourcePlaylistID,
                    by: -removals.reduce(0) { $0 + $1.positions.count }
                )
            }
            invalidateTracksCache(playlistID: destinationPlaylistID)
            await refreshCurrentPlaylistMutationDetail(
                for: [sourcePlaylistID, destinationPlaylistID]
            )
            trackMutationToastText = LocalizedText(SpotiglassL10n.format(
                "playlist.mutation.movedToPlaylist",
                Int64(uris.count),
                destinationName
            ))
        } catch {
            trackMutationToastText = Self.failureText(error, operation: .moveBetweenPlaylists)
        }
    }

    func favoriteRows(_ rows: [TrackRowViewModel]) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else {
            trackMutationToastText = LocalizedText(SpotiglassL10n.string("playlist.mutation.noEligibleTracks"))
            return
        }
        guard await ensureEditAllowed(.addToLikedSongs) else { return }
        do {
            try await api.saveTracks(ids: ids)
            dropSavedTrackStatesTheProviderNowAnswers()
            for id in ids {
                savedTrackStates[id] = true
            }
            // Albums whose songs these are may have changed too; they load again when shown.
            savedAlbumStates = [:]
            invalidateLikedSongsCache()
            await refreshLikedSongsDetailAfterMutation()
            trackMutationToastText = LocalizedText(SpotiglassL10n.format(
                "playlist.mutation.addedToLikedSongs",
                Int64(ids.count)
            ))
        } catch {
            trackMutationToastText = Self.failureText(error, operation: .addToLikedSongs)
        }
    }

    /// `confirmed` is false from the menu; a provider whose removal also empties playlists
    /// (`MusicLibraryEdits.confirmLibraryRemoval`) then asks first and calls back with true.
    func unfavoriteRows(_ rows: [TrackRowViewModel], confirmed: Bool = false) async {
        let ids = catalogTrackIDs(for: rows)
        guard !ids.isEmpty else {
            trackMutationToastText = LocalizedText(SpotiglassL10n.string("playlist.mutation.noEligibleTracks"))
            return
        }
        if !confirmed, supportedLibraryEdits.contains(.confirmLibraryRemoval) {
            pendingLibraryRemoval = .songs(rows)
            return
        }
        guard await ensureEditAllowed(.removeFromLikedSongs) else { return }
        do {
            try await api.removeSavedTracks(ids: ids)
            dropSavedTrackStatesTheProviderNowAnswers()
            for id in ids {
                savedTrackStates[id] = false
            }
            // Albums whose songs these are may have changed too; they load again when shown.
            savedAlbumStates = [:]
            invalidateLikedSongsCache()
            recountPlaylistTracksAfterLibraryRemoval()
            await refreshLikedSongsDetailAfterMutation()
            trackMutationToastText = LocalizedText(SpotiglassL10n.format(
                "playlist.mutation.removedFromLikedSongs",
                Int64(ids.count)
            ))
        } catch {
            trackMutationToastText = Self.failureText(error, operation: .removeFromLikedSongs)
        }
    }

    /// Creates a new playlist under the signed-in user's account and adds
    /// `rows` to it. The created summary is inserted at the top of the
    /// sidebar so the user immediately sees it.
    func createPlaylistWithRows(name: String, rows: [TrackRowViewModel]) async {
        guard let userID = currentUserID, !userID.isEmpty else {
            let service = MusicServiceSelection.current
            trackMutationToastText = LocalizedText(SpotiglassL10n.format("playlist.mutation.signInToCreate", service.displayName))
            return
        }
        guard await ensureEditAllowed(.createPlaylist) else { return }
        do {
            let uris = playableURIs(for: rows)
            let created = try await api.createPlaylist(userID: userID, name: name, isPublic: false, trackURIs: uris)
            insertSidebarPlaylist(created, refreshedTrackCount: uris.count)
            trackMutationToastText = LocalizedText(uris.isEmpty
                ? SpotiglassL10n.format("playlist.mutation.createdPlaylist", created.name)
                : SpotiglassL10n.format(
                    "playlist.mutation.createdPlaylistWithTracks",
                    created.name,
                    Int64(uris.count)
                ))
        } catch {
            trackMutationToastText = Self.failureText(error, operation: .createPlaylist)
        }
    }

    /// Renames an owned playlist and updates the sidebar and detail surfaces before
    /// the Spotify request completes. A failed request restores the previous name.
    func renamePlaylist(id: String, name: String) async {
        guard let previous = playlistsByID[id] else { return }
        guard let currentUserID = currentUserID,
              !currentUserID.isEmpty,
              previous.ownerID == currentUserID
        else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compared with what the editor showed: confirming a nameless playlist's stand-in unchanged
        // must not save the stand-in as its name (#547).
        guard !trimmedName.isEmpty, trimmedName != previous.name else { return }

        let renamed = MusicPlaylistSummary(
            id: previous.id,
            name: trimmedName,
            ownerID: previous.ownerID,
            ownerName: previous.ownerName,
            imageURL: previous.imageURL,
            trackCount: previous.trackCount,
            snapshotID: previous.snapshotID,
            isCollaborative: previous.isCollaborative
        )
        applyPlaylistName(renamed)

        guard await ensureEditAllowed(.renamePlaylist) else {
            applyPlaylistName((playlistsByID[id] ?? previous).renamed(previous.nameAsSent))
            return
        }

        do {
            try await api.updatePlaylist(playlistID: id, name: trimmedName)
        } catch {
            // Only the name goes back: a track count that arrived meanwhile stays.
            applyPlaylistName((playlistsByID[id] ?? previous).renamed(previous.nameAsSent))
            trackMutationToastText = Self.failureText(error, operation: .renamePlaylist)
        }
    }

    /// User-owned playlists (excluding the virtual liked-songs row) for menu listing.
    func userOwnedPlaylistsForMenu(excludingPlaylistID excluding: String?) -> [MusicPlaylistSummary] {
        let me = currentUserID ?? ""
        return playlistState.currentValue?.compactMap { row -> MusicPlaylistSummary? in
            guard let summary = playlistsByID[row.id], summary.ownerID == me else { return nil }
            if let excluding, summary.id == excluding { return nil }
            return summary
        } ?? []
    }

    // MARK: - Internal helpers

    /// Stops an edit the account may not make before the provider can issue the request. This
    /// is intentionally a redirecting toast rather than a silent no-op, so the service's own fix
    /// (Spotify: Settings ▸ Account ▸ Reconnect) is discoverable.
    func ensureEditAllowed(_ operation: PlaylistMutationOperation) async -> Bool {
        guard let editPermissions, let failure = await editPermissions.missingPermission(for: operation) else {
            return true
        }
        trackMutationToastText = Self.failureText(failure, operation: operation)
        return false
    }

    /// Converts a mutation failure into user copy without leaking Spotify's
    /// generic 403 reason phrase. The operation-specific variants name the
    /// capability and point at the existing reconnect control.
    /// The note for a failed edit, looked up when shown so it follows a language switch (#571).
    /// The service is the one the edit failed on, even if another is picked while the note shows.
    static func failureText(_ error: Error, operation: PlaylistMutationOperation = .generic) -> LocalizedText {
        let service = MusicServiceSelection.current
        return LocalizedText(describeFailure(error, operation: operation, service: service))
    }

    static func describeFailure(
        _ error: Error,
        operation: PlaylistMutationOperation = .generic,
        service: MusicService = MusicServiceSelection.current
    ) -> String {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .insufficientScope, .forbidden:
                switch operation {
                case .addToLikedSongs, .removeFromLikedSongs:
                    return SpotiglassL10n.string("playlist.mutation.likedSongsRequiresReconnect")
                case .addToPlaylist, .moveBetweenPlaylists, .createPlaylist, .renamePlaylist,
                     .removeFromPlaylist, .deletePlaylist, .saveAlbum, .reorderPlaylist:
                    return SpotiglassL10n.string("playlist.mutation.playlistRequiresReconnect")
                case .generic:
                    break
                }
            default:
                break
            }
            return apiError.localizedDescription
        }
        // An Apple Music edit's failure reads as Apple Music's, never as Spotify's (#470).
        return BrowsingDisplayError.appleMusic(for: error, service: service)?.message
            ?? MusicServiceErrorText.userMessage(for: error, service: service)
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

    private func applyPlaylistName(_ playlist: MusicPlaylistSummary) {
        playlistsByID[playlist.id] = playlist
        // The window title is the breadcrumb trail; it kept the old name (#395).
        breadcrumbPath = breadcrumbPath.map { crumb in
            guard crumb.kind == .playlist(id: playlist.id), crumb.label != playlist.name else { return crumb }
            return BrowserBreadcrumb(
                id: crumb.id,
                label: playlist.name,
                systemImage: crumb.systemImage,
                kind: crumb.kind,
                fallbackKey: Self.playlistCrumbFallbackKey(for: playlist)
            )
        }

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

        try? cache.savePlaylists(playlistsInSidebarOrder(), cachedAt: now())
    }

    func invalidateTracksCache(playlistID: String) {
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

    func invalidateLikedSongsCache() {
        invalidateTracksCache(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
    }

    func refreshLikedSongsDetailAfterMutation() async {
        guard sidebarSelection == .likedSongs else { return }
        await revalidateLikedSongs(session: detailSession)
    }

    func refreshCurrentPlaylistMutationDetail(for playlistIDs: [String]) async {
        guard case let .playlist(currentPlaylistID) = sidebarSelection,
              playlistIDs.contains(currentPlaylistID),
              currentPlaylistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              playlistsByID[currentPlaylistID] != nil || knownPlaylistSummariesByID[currentPlaylistID] != nil
        else { return }
        await loadTracks(for: currentPlaylistID, refreshCachedData: true, session: detailSession)
    }

    private func insertSidebarPlaylist(_ summary: MusicPlaylistSummary, refreshedTrackCount: Int) {
        let normalised = summary.with(trackCount: refreshedTrackCount)
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
        try? cache.savePlaylists(playlistsInSidebarOrder(), cachedAt: now())
        invalidateLibraryContinuationCache()
    }
}
