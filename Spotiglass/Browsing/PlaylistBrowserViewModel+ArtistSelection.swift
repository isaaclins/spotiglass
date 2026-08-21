import Foundation

extension PlaylistBrowserViewModel {
    func selectArtist(
        id: String,
        forceRefresh: Bool = false,
        origin: BrowserNavigationOrigin = .reset,
        displayName: String? = nil
    ) async {
        registerNavigationTransition(to: .artist(id))
        applyBreadcrumbForArtist(
            id: id,
            displayName: displayName,
            origin: origin
        )
        let nowDate = now()
        detailLoadTask?.cancel()

        if !forceRefresh,
           let cached = cachedArtistSnapshots[id],
           nowDate.timeIntervalSince(cached.fetchedAt) < artistDetailCacheTTL {
            currentArtistAlbumsPaging = cached.snapshot.paging
            let cachedVM = ArtistDetailViewModel(
                artist: cached.snapshot.artistDetail,
                tracks: cached.snapshot.tracks,
                albums: cached.snapshot.albums,
                canLoadMoreAlbums: cached.snapshot.paging?.nextURL != nil,
                isLoadingMoreAlbums: cached.snapshot.paging?.isLoading == true
            )
            ignoreNextNilSidebarSelectionForDetail = true
            sidebarSelection = nil
            detailSession += 1
            detailState = .loaded(.artist(cachedVM))
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: cached.snapshot.artistDetail.name)
            return
        }
        if let lastSelection = lastArtistSelectionAt[id],
           nowDate.timeIntervalSince(lastSelection) < artistSelectionDebounceWindow,
           artistDetailLoadTasks[id] != nil {
            artistFetchMetrics.coalescedRequests += 1
            return
        }
        lastArtistSelectionAt[id] = nowDate

        ignoreNextNilSidebarSelectionForDetail = true
        sidebarSelection = nil
        detailSession += 1
        let session = detailSession
        detailState = .loading
        do {
            let snapshot = try await loadArtistDetailSnapshot(id: id, preferCached: false)
            guard session == detailSession else { return }
            currentArtistAlbumsPaging = snapshot.paging
            if snapshot.usedStaleCache {
                artistFetchMetrics.staleResponsesServed += 1
                let staleVM = ArtistDetailViewModel(
                    artist: snapshot.artistDetail,
                    tracks: snapshot.tracks,
                    albums: snapshot.albums,
                    canLoadMoreAlbums: snapshot.paging?.nextURL != nil
                )
                detailState = .refreshing(.artist(staleVM))
                artistFetchMetrics.forcedRefreshRuns += 1
                let refreshed = try await loadArtistDetailSnapshot(id: id, preferCached: false)
                guard session == detailSession else { return }
                currentArtistAlbumsPaging = refreshed.paging
                let refreshedVM = ArtistDetailViewModel(
                    artist: refreshed.artistDetail,
                    tracks: refreshed.tracks,
                    albums: refreshed.albums,
                    canLoadMoreAlbums: refreshed.paging?.nextURL != nil
                )
                cachedArtistSnapshots[id] = CachedArtistSnapshot(snapshot: refreshed, fetchedAt: now())
                detailState = .loaded(.artist(refreshedVM))
                refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: refreshed.artistDetail.name)
                return
            }
            guard session == detailSession else { return }
            let vm = ArtistDetailViewModel(
                artist: snapshot.artistDetail,
                tracks: snapshot.tracks,
                albums: snapshot.albums,
                canLoadMoreAlbums: snapshot.paging?.nextURL != nil
            )
            cachedArtistSnapshots[id] = CachedArtistSnapshot(snapshot: snapshot, fetchedAt: now())
            detailState = .loaded(.artist(vm))
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: snapshot.artistDetail.name)
        } catch is CancellationError {
            return
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }
}
