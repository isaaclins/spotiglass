import Foundation

extension PlaylistBrowserViewModel {
    func loadTracks(for playlistID: String, refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        guard let playlist = playlistsByID[playlistID] ?? knownPlaylistSummariesByID[playlistID] else {
            detailState = .error(BrowsingDisplayError(
                title: SpotiglassL10n.string("error.browsing.playlistUnavailable.title"),
                message: SpotiglassL10n.string("error.browsing.playlistUnavailable.gone"),
                canRetry: true
            ))
            return
        }

        let playlistRow = PlaylistRowViewModel(playlist)

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: playlist.id, snapshotID: playlist.snapshotID, now: now(), maxAge: maxCacheAge) {
            if cachedTracks.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.noTracks.emptyPlaylist"))
            } else {
                await showPlaylistRows(
                    PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(cachedTracks)),
                    session: session
                )
                guard session == detailSession else { return }
            }
            if let last = lastTracksRevalidationByID[playlist.id],
               last.snapshotID == playlist.snapshotID,
               now().timeIntervalSince(last.at) < tracksRevalidateMinInterval {
                return
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: playlist.id, snapshotID: playlist.snapshotID) {
            if staleTracks.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.noTracks.emptyPlaylist"))
            } else {
                await showPlaylistRows(
                    PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(staleTracks)),
                    refreshing: true,
                    session: session
                )
                guard session == detailSession else { return }
            }
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        // Songs the provider read earlier (Apple Music counts every playlist after launch) show
        // at once; the read below replaces them if the playlist changed since (#442).
        if refreshCachedData, let lastRead = await api.lastReadPlaylistTracks(playlistID: playlist.id) {
            guard session == detailSession else { return }
            await showPlaylistRows(
                PlaylistDetailViewModel(playlist: withSidebarTrackCount(playlistRow), tracks: TrackRowViewModel.numberedPlaylistRows(lastRead)),
                session: session
            )
            guard session == detailSession else { return }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        // No cached tracks to fall back to, so show a plain loading state.
        // Carrying over the previous surface (for example Home) as a refreshing
        // placeholder would make a revalidation failure surface unrelated content
        // wrapped in a stale-cache banner instead of a terminal error.
        // Asking the provider for earlier songs above can wait, and another surface may have
        // taken over meanwhile: setting `.loading` then would cover it for good.
        guard session == detailSession else { return }
        detailState = .loading
        await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
    }

    private func revalidatePlaylistTracks(playlist: MusicPlaylistSummary, playlistRow: PlaylistRowViewModel, session: Int) async {
        let reorderGeneration = reorderGenerationByPlaylistID[playlist.id]
        do {
            // Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum
            // limit of 50 (the February 2026 rename also tightened the cap from
            // the legacy `/tracks` endpoint's 100). Passing 100 yields HTTP 400
            // invalid_request and breaks any playlist with more than 50 tracks.
            let tracks = try await api.playlistTracks(playlistID: playlist.id, limit: 50, maxPages: 200)
            // A new order was saved from here while this read ran: it lists the old order, and the
            // rows on screen have the new one (#543). With no rows of this playlist on screen
            // (opened again meanwhile) the read is all there is, so it is shown.
            if reorderGenerationByPlaylistID[playlist.id] != reorderGeneration,
               session == detailSession,
               case let .playlist(shown)? = detailState.currentValue, shown.playlist.id == playlist.id {
                if case let .refreshing(content) = detailState { detailState = .loaded(content) }
                return
            }
            try? cache.saveTracks(tracks, playlistID: playlist.id, snapshotID: playlist.snapshotID, cachedAt: now())
            invalidateLibraryContinuationCache()
            lastTracksRevalidationByID[playlist.id] = (playlist.snapshotID, now())
            guard session == detailSession else { return }
            if tracks.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.noTracks.emptyPlaylist"))
            } else {
                await showPlaylistRows(
                    PlaylistDetailViewModel(
                        playlist: withSidebarTrackCount(playlistRow),
                        tracks: TrackRowViewModel.numberedPlaylistRows(tracks)
                    ),
                    session: session
                )
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

    /// Rows a long list shows before the rest: a screen and a bit of a tall window.
    static let firstScreenRowCount = 60
    /// How long the first screen of rows gets to draw before the rest is added.
    static let firstScreenDrawTime: Duration = .milliseconds(16)

    /// Shows a playlist's rows. The list lays out every row it is given before it draws again,
    /// so 800 songs at once kept it blank for most of a second (#442). A long list that isn't
    /// on screen yet shows one screen of rows first, then all of them below it. Every change
    /// lays out the whole list again, so the rest goes in one step: adding it in smaller ones
    /// cost more in total, and more for each step than the one before. A list already showing
    /// the start of these rows gets the rest the same way; any other list on screen is replaced
    /// at once, as cutting it back would make it jump.
    /// `isComplete`: `detail` holds every row of the list, not the first page of a read still
    /// running.
    func showPlaylistRows(_ detail: PlaylistDetailViewModel, refreshing: Bool = false, isComplete: Bool = true, session: Int) async {
        if isComplete {
            completeRowsOnScreen = (session, detail.playlist.id, detail.tracks)
        }
        let state: (PlaylistDetailViewModel) -> BrowsingLoadState<BrowsingDetailContent> = { shown in
            refreshing ? .refreshing(.playlist(shown)) : .loaded(.playlist(shown))
        }
        if case let .playlist(shown)? = detailState.currentValue, shown.playlist.id == detail.playlist.id {
            // A fresh read that found what is on screen changes nothing: setting it anyway lays
            // the whole list out again.
            let next = state(detail)
            if detailState != next { detailState = next }
            return
        }
        guard detail.tracks.count > Self.firstScreenRowCount else {
            detailState = state(detail)
            return
        }
        let firstScreenRows = Array(detail.tracks.prefix(Self.firstScreenRowCount))
        detailState = state(PlaylistDetailViewModel(playlist: detail.playlist, tracks: firstScreenRows))
        try? await Task.sleep(for: Self.firstScreenDrawTime)
        // Another surface, or a newer read of this one, took over meanwhile. A new header for
        // the same rows (a count or a name that arrived) is kept, with the rest added below.
        guard session == detailSession,
              case let .playlist(shown)? = detailState.currentValue,
              shown.playlist.id == detail.playlist.id,
              shown.tracks == firstScreenRows else { return }
        let full = BrowsingDetailContent.playlist(PlaylistDetailViewModel(playlist: shown.playlist, tracks: detail.tracks))
        switch detailState {
        case .loaded: detailState = .loaded(full)
        case .refreshing: detailState = .refreshing(full)
        case let .staleCache(_, error): detailState = .staleCache(full, error)
        default: return
        }
    }

    /// The header row with the sidebar's count when a newer one arrived while the tracks
    /// loaded (Apple Music counts arrive after the listing, #407).
    func withSidebarTrackCount(_ row: PlaylistRowViewModel) -> PlaylistRowViewModel {
        guard api.listsPlaylistsWithoutTrackCounts,
              let summary = playlistsByID[row.id], summary.trackCount != row.trackCount else { return row }
        return PlaylistRowViewModel(summary)
    }

    private func playlistIsOwnedByCurrentUser(_ playlist: MusicPlaylistSummary) -> Bool {
        guard let currentUserSpotifyID, !currentUserSpotifyID.isEmpty else { return false }
        return currentUserSpotifyID == playlist.ownerID
    }
}
