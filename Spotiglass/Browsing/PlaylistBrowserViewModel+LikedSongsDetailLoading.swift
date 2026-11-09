import Foundation

extension PlaylistBrowserViewModel {
    func loadLikedSongsTracks(refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        let virtualID = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        let snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: virtualID, snapshotID: snapshotID, now: now(), maxAge: maxCacheAge) {
            guard await setLikedSongsDetailState(from: cachedTracks, session: session) else { return }
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
            guard await setLikedSongsDetailState(from: staleTracks, session: session) else { return }
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
        await revalidateLikedSongs(session: session, showsFirstPage: true)
    }

    /// Shows the first page of a Liked Songs read that is still running, while nothing is on
    /// screen yet: reading a thousand Apple Music library songs takes about a second (#442).
    /// The full read replaces it; rows are only added below, so nothing moves.
    private func showLikedSongsFirstPage(_ first: MusicSavedTracksResult, session: Int, generation: Int) async {
        guard !first.tracks.isEmpty, session == detailSession,
              generation == likedSongsMutationGeneration,
              case .loading = detailState else { return }
        // The same owner line as the full list, so the header doesn't change above the rows.
        let profile = try? await api.currentUserProfile()
        guard session == detailSession, generation == likedSongsMutationGeneration,
              case .loading = detailState else { return }
        let row = PlaylistRowViewModel(
            likedSongsOwnerName: profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            // Only a total the service reported; a partial read's own length isn't one.
            totalTrackCount: first.totalAvailable > first.tracks.count ? first.totalAvailable : nil,
            artworkURL: firstLikedSongsArtwork(from: first.tracks)
        )
        likedSongsFirstPageSession = session
        await showPlaylistRows(
            PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(first.tracks)),
            refreshing: true,
            session: session
        )
    }

    /// The detail to play from. While Liked Songs show only the first page of a read that is
    /// still running (#442), playing waits for that read: the queue gets every song, not just
    /// the first page, and nothing would add the rest later. Everything else plays as shown.
    func detailForPlayback(_ detail: PlaylistDetailViewModel) async -> PlaylistDetailViewModel {
        guard detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              likedSongsFirstPageSession == detailSession else { return detail }
        if let read = likedSongsRevalidationTask, let full = try? await read.value, !full.tracks.isEmpty {
            return PlaylistDetailViewModel(playlist: detail.playlist, tracks: TrackRowViewModel.numberedPlaylistRows(full.tracks))
        }
        if case let .playlist(shown)? = detailState.currentValue, shown.playlist.id == detail.playlist.id {
            return shown
        }
        return detail
    }

    private func setLikedSongsDetailState(from tracks: [MusicPlaylistTrackItem], session: Int) async -> Bool {
        guard session == detailSession else { return false }
        if tracks.isEmpty {
            detailState = .empty(SpotiglassL10n.string("browser.empty.noLikedSongs"))
            return true
        }
        let profile = try? await api.currentUserProfile()
        guard session == detailSession else { return false }
        let ownerName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = PlaylistRowViewModel(
            likedSongsOwnerName: ownerName,
            totalTrackCount: tracks.count,
            artworkURL: firstLikedSongsArtwork(from: tracks)
        )
        await showPlaylistRows(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(tracks)), session: session)
        return session == detailSession
    }

    private func firstLikedSongsArtwork(from tracks: [MusicPlaylistTrackItem]) -> URL? {
        for item in tracks.prefix(4) {
            if case let .track(t) = item.content { return t.albumArtworkURL }
            if case let .episode(e) = item.content { return e.artworkURL }
        }
        return nil
    }

    /// `showsFirstPage`: nothing is on screen yet, so the read's first page is shown as soon as
    /// it arrives.
    func revalidateLikedSongs(session: Int, showsFirstPage: Bool = false) async {
        let mutationGeneration = likedSongsMutationGeneration
        do {
            let firstPage: (@Sendable (MusicSavedTracksResult) async -> Void)? = showsFirstPage ? { [weak self] first in
                // Not awaited: the read goes on while the rows draw.
                Task { @MainActor in
                    await self?.showLikedSongsFirstPage(first, session: session, generation: mutationGeneration)
                }
            } : nil
            let result = try await likedSongsRevalidationResult(firstPage: firstPage)
            guard mutationGeneration == likedSongsMutationGeneration else { return }
            try? cache.saveTracks(
                result.tracks,
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                snapshotID: SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                cachedAt: now()
            )
            invalidateLibraryContinuationCache()
            lastLikedSongsRevalidationAt = now()
            lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = (
                SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                now()
            )
            guard session == detailSession else { return }
            let profile = try? await api.currentUserProfile()
            guard session == detailSession,
                  mutationGeneration == likedSongsMutationGeneration else { return }
            let ownerName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = PlaylistRowViewModel(
                likedSongsOwnerName: ownerName,
                totalTrackCount: max(result.totalAvailable, result.tracks.count),
                artworkURL: firstLikedSongsArtwork(from: result.tracks)
            )
            if result.tracks.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.empty.noLikedSongs"))
            } else {
                await showPlaylistRows(
                    PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(result.tracks)),
                    session: session
                )
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard session == detailSession,
                  mutationGeneration == likedSongsMutationGeneration else { return }
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

    private func likedSongsRevalidationResult(
        firstPage: (@Sendable (MusicSavedTracksResult) async -> Void)? = nil
    ) async throws -> MusicSavedTracksResult {
        if let inFlight = likedSongsRevalidationTask {
            return try await inFlight.value
        }
        let generation = likedSongsMutationGeneration
        let task = Task { [api] in
            if let firstPage {
                return try await api.currentUserSavedTracks(limit: 50, maxPages: nil, firstPage: firstPage)
            }
            return try await api.currentUserSavedTracks(limit: 50, maxPages: nil)
        }
        likedSongsRevalidationTask = task
        likedSongsRevalidationTaskGeneration = generation
        defer {
            if likedSongsRevalidationTaskGeneration == generation {
                likedSongsRevalidationTask = nil
                likedSongsRevalidationTaskGeneration = nil
            }
        }
        return try await task.value
    }
}
