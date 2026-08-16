import Foundation

extension PlaylistBrowserViewModel {
    func loadLikedSongsTracks(refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        let virtualID = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        let snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: virtualID, snapshotID: snapshotID, now: now(), maxAge: maxCacheAge) {
            await setLikedSongsDetailState(from: cachedTracks)
            if shouldSkipAutomaticLikedSongsRevalidation() {
                return
            }
            if let last = lastTracksRevalidationByID[virtualID],
               last.snapshotID == snapshotID,
               now().timeIntervalSince(last.at) < tracksRevalidateMinInterval {
                return
            }
            await revalidateLikedSongs(session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: virtualID, snapshotID: snapshotID) {
            await setLikedSongsDetailState(from: staleTracks)
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidateLikedSongs(session: session)
            return
        }

        // No liked-songs cache to fall back to, so show a plain loading state.
        // Carrying over the previous surface (for example Home) as a refreshing
        // placeholder would make a revalidation failure surface unrelated content
        // wrapped in a stale-cache banner instead of a terminal error.
        detailState = .loading
        guard session == detailSession else { return }
        await revalidateLikedSongs(session: session)
    }

    private func setLikedSongsDetailState(from tracks: [SpotifyPlaylistTrackItem]) async {
        if tracks.isEmpty {
            detailState = .empty(SpotiglassL10n.string("browser.empty.noLikedSongs"))
            return
        }
        let profile = try? await api.currentUserProfile()
        let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = trimmedName.isEmpty ? "You" : trimmedName
        let row = PlaylistRowViewModel(
            likedSongsOwnerDisplay: owner,
            totalTrackCount: tracks.count,
            artworkURL: firstLikedSongsArtwork(from: tracks)
        )
        detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
    }

    private func firstLikedSongsArtwork(from tracks: [SpotifyPlaylistTrackItem]) -> URL? {
        for item in tracks.prefix(4) {
            if case let .track(t) = item.content { return t.albumArtworkURL }
            if case let .episode(e) = item.content { return e.artworkURL }
        }
        return nil
    }

    private func revalidateLikedSongs(session: Int) async {
        do {
            let result = try await likedSongsRevalidationResult()
            try? cache.saveTracks(
                result.tracks,
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                snapshotID: SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                cachedAt: now()
            )
            lastLikedSongsRevalidationAt = now()
            lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = (
                SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                now()
            )
            guard session == detailSession else { return }
            let profile = try? await api.currentUserProfile()
            let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = trimmedName.isEmpty ? "You" : trimmedName
            let row = PlaylistRowViewModel(
                likedSongsOwnerDisplay: owner,
                totalTrackCount: max(result.totalAvailable, result.tracks.count),
                artworkURL: firstLikedSongsArtwork(from: result.tracks)
            )
            if result.tracks.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.empty.noLikedSongs"))
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(result.tracks))))
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard session == detailSession else { return }
            let displayError = Self.displayError(for: error)
            if let existingDetail = detailState.currentValue {
                detailState = .staleCache(existingDetail, displayError)
            } else {
                detailState = .error(displayError)
            }
        }
    }

    private func shouldSkipAutomaticLikedSongsRevalidation() -> Bool {
        guard likedSongsRevalidationTask == nil,
              let lastRevalidation = lastLikedSongsRevalidationAt else {
            return false
        }
        return now().timeIntervalSince(lastRevalidation) < likedSongsAutoRefreshMinInterval
    }

    private func likedSongsRevalidationResult() async throws -> SpotifySavedTracksResult {
        if let inFlight = likedSongsRevalidationTask {
            return try await inFlight.value
        }
        let task = Task { [api] in
            try await api.currentUserSavedTracks(limit: 50, maxPages: 20)
        }
        likedSongsRevalidationTask = task
        defer { likedSongsRevalidationTask = nil }
        return try await task.value
    }
}
