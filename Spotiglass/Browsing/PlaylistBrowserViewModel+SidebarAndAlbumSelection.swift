import Foundation

extension PlaylistBrowserViewModel {
    func selectSidebar(_ selection: SidebarSelection?, origin: BrowserNavigationOrigin = .reset) async {
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = nil
        pendingAdjacentPlaylistOffset = 0
        guard let selection else {
            sidebarSelection = nil
            if ignoreNextNilSidebarSelectionForDetail {
                ignoreNextNilSidebarSelectionForDetail = false
                return
            }
            if origin != .backStackReplay {
                breadcrumbPath = []
            }
            currentNavigationTarget = nil
            syncCanNavigateBack()
            detailSession += 1
            detailState = .empty(SpotiglassL10n.string("browser.empty.pickSomething"))
            return
        }

        // Pinned-item taps are dispatched in the view layer (it owns the
        // `PinnedItemsStore` and the playback view-model needed for tracks).
        // Just record the selection so list highlight stays in sync.
        if case .pinnedItem = selection {
            sidebarSelection = selection
            return
        }

        registerNavigationTransition(to: .sidebar(selection))
        applyBreadcrumbForSidebar(selection, origin: origin)
        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        sidebarSelection = selection
        await scheduleDetailLoad(for: selection, refreshCachedData: true, session: session)
    }

    /// Loads an album by ID and renders it through the existing playlist
    /// detail content. Album metadata (title / artist line / artwork) is
    /// supplied by the caller (typically a pinned item snapshot) so the
    /// header is populated even when offline.
    func selectAlbum(
        id: String,
        displayTitle: String,
        displaySubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin = .reset
    ) async {
        clearTrackSelection()
        registerNavigationTransition(to: .album(id: id, title: displayTitle, subtitle: displaySubtitle, artworkURL: artworkURL))
        applyBreadcrumbForAlbum(
            id: id,
            title: displayTitle,
            subtitle: displaySubtitle,
            artworkURL: artworkURL,
            origin: origin
        )
        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        detailLoadTask?.cancel()
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadAlbumDetail(
                id: id,
                displayTitle: displayTitle,
                displaySubtitle: displaySubtitle,
                artworkURL: artworkURL,
                session: session
            )
        }
        detailLoadTask = task
        await task.value
        if generation == detailLoadGeneration {
            detailLoadTask = nil
        }
    }

    func selectPlaylist(summary: SpotifyPlaylistSummary, origin: BrowserNavigationOrigin = .reset) async {
        knownPlaylistSummariesByID[summary.id] = summary
        await selectSidebar(.playlist(summary.id), origin: origin)
    }

    func selectPlaylist(id: String?, origin: BrowserNavigationOrigin = .reset) async {
        if let id {
            await selectSidebar(.playlist(id), origin: origin)
        } else {
            await selectSidebar(nil, origin: origin)
        }
    }

    private func loadAlbumDetail(
        id: String,
        displayTitle: String,
        displaySubtitle: String,
        artworkURL: URL?,
        session: Int
    ) async {
        guard !Task.isCancelled else { return }
        detailState = .loading
        do {
            let profile = try? await api.currentUserProfile()
            let market = profile?.country
            let tracks = try await api.albumTracks(albumID: id, market: market, limit: 50).map { track in
                guard track.albumArtworkURL == nil, let artworkURL else {
                    return track
                }
                return SpotifyTrack(
                    id: track.id,
                    name: track.name,
                    artists: track.artists,
                    artistRefs: track.artistRefs,
                    albumArtworkURL: artworkURL,
                    albumName: track.albumName,
                    albumID: track.albumID,
                    durationMilliseconds: track.durationMilliseconds,
                    isExplicit: track.isExplicit,
                    isPlayable: track.isPlayable,
                    linkedFromID: track.linkedFromID,
                    uri: track.uri
                )
            }
            guard session == detailSession else { return }
            let header = PlaylistRowViewModel(
                albumDisplayName: displayTitle,
                artistsDisplay: displaySubtitle,
                totalTrackCount: tracks.count,
                artworkURL: artworkURL,
                albumID: id
            )
            let trackRows = TrackRowViewModel.numberedTopTracks(tracks)
            if trackRows.isEmpty {
                detailState = .empty(SpotiglassL10n.string("browser.empty.albumNoTracks"))
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: header, tracks: trackRows)))
            }
        } catch is CancellationError {
            return
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }
}
