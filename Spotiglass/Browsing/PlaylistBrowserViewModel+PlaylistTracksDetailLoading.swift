import Foundation

extension PlaylistBrowserViewModel {
    func loadTracks(for playlistID: String, refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        guard let playlist = playlistsByID[playlistID] else {
            detailState = .error(
                BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.playlistUnavailable.title"),
                    message: SpotiglassL10n.string("error.browsing.playlistUnavailable.gone"),
                    canRetry: true
                ))
            return
        }

        let playlistRow = PlaylistRowViewModel(playlist)

        if refreshCachedData,
            let cachedTracks = try? cache.loadTracks(
                playlistID: playlist.id, snapshotID: playlist.snapshotID, now: now(), maxAge: maxCacheAge)
        {
            if cachedTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(
                    .playlist(
                        PlaylistDetailViewModel(
                            playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(cachedTracks))))
            }
            if let last = lastTracksRevalidationByID[playlist.id],
                last.snapshotID == playlist.snapshotID,
                now().timeIntervalSince(last.at) < tracksRevalidateMinInterval
            {
                return
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        if refreshCachedData,
            let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: playlist.id, snapshotID: playlist.snapshotID)
        {
            if staleTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(
                    .playlist(
                        PlaylistDetailViewModel(
                            playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(staleTracks))))
            }
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        // No cached tracks to fall back to, so show a plain loading state.
        // Carrying over the previous surface (for example Home) as a refreshing
        // placeholder would make a revalidation failure surface unrelated content
        // wrapped in a stale-cache banner instead of a terminal error.
        detailState = .loading
        guard session == detailSession else { return }
        await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
    }

    private func revalidatePlaylistTracks(
        playlist: SpotifyPlaylistSummary, playlistRow: PlaylistRowViewModel, session: Int
    ) async {
        do {
            // Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum
            // limit of 50 (the February 2026 rename also tightened the cap from
            // the legacy `/tracks` endpoint's 100). Passing 100 yields HTTP 400
            // invalid_request and breaks any playlist with more than 50 tracks.
            let tracks = try await api.playlistTracks(playlistID: playlist.id, limit: 50, maxPages: 200)
            try? cache.saveTracks(tracks, playlistID: playlist.id, snapshotID: playlist.snapshotID, cachedAt: now())
            lastTracksRevalidationByID[playlist.id] = (playlist.snapshotID, now())
            guard session == detailSession else { return }
            if tracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(
                    .playlist(
                        PlaylistDetailViewModel(
                            playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard session == detailSession else { return }
            if case SpotifyAPIError.forbidden = error, !playlistIsOwnedByCurrentUser(playlist) {
                let locked = BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.followedPlaylistLocked.title"),
                    message: SpotiglassL10n.string("error.browsing.followedPlaylistLocked.message"),
                    canRetry: false,
                    lockedPlaylist: LockedPlaylistInfo(playlistID: playlist.id, name: playlist.name)
                )
                if let existingDetail = detailState.currentValue {
                    detailState = .staleCache(existingDetail, locked)
                } else {
                    detailState = .error(locked)
                }
                return
            }
            let displayError = Self.displayError(for: error)
            if let existingDetail = detailState.currentValue {
                detailState = .staleCache(existingDetail, displayError)
            } else {
                detailState = .error(displayError)
            }
        }
    }

    private func playlistIsOwnedByCurrentUser(_ playlist: SpotifyPlaylistSummary) -> Bool {
        guard let currentUserSpotifyID, !currentUserSpotifyID.isEmpty else { return false }
        return currentUserSpotifyID == playlist.ownerID
    }
}
