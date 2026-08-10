import Foundation

extension PlaylistBrowserViewModel {
    func loadMoreArtistAlbums() async {
        guard case .loaded(.artist(let detail)) = detailState,
            var paging = currentArtistAlbumsPaging,
            !paging.isLoading,
            let nextURL = paging.nextURL
        else {
            return
        }

        paging.isLoading = true
        currentArtistAlbumsPaging = paging
        detailState = .loaded(
            .artist(
                ArtistDetailViewModel(
                    artist: detail.artist,
                    tracks: paging.tracks,
                    albums: paging.albums,
                    canLoadMoreAlbums: true,
                    isLoadingMoreAlbums: true
                )
            ))

        do {
            if paging.seenNextURLs.contains(nextURL.absoluteString) {
                paging.nextURL = nil
            } else {
                paging.seenNextURLs.insert(nextURL.absoluteString)
                let page = try await api.artistAlbumsPage(
                    id: paging.artistID,
                    includeGroups: paging.includeGroups,
                    limit: paging.limit,
                    offset: paging.nextOffset,
                    nextURL: nextURL,
                    cacheMode: .bypassCache
                )
                paging.albums = Self.dedupeAlbums(paging.albums + page.items)
                paging.nextURL = page.next
                paging.nextOffset += paging.limit
            }
            paging.isLoading = false
            currentArtistAlbumsPaging = paging
            let refreshed = ArtistDetailViewModel(
                artist: detail.artist,
                tracks: paging.tracks,
                albums: paging.albums,
                canLoadMoreAlbums: paging.nextURL != nil,
                isLoadingMoreAlbums: false
            )
            cachedArtistSnapshots[detail.artist.id] = CachedArtistSnapshot(
                snapshot: ArtistDetailSnapshot(
                    artistDetail: detail.artist,
                    albums: paging.albums,
                    tracks: paging.tracks,
                    usedStaleCache: false,
                    paging: paging
                ),
                fetchedAt: now()
            )
            detailState = .loaded(.artist(refreshed))
        } catch {
            paging.isLoading = false
            currentArtistAlbumsPaging = paging
            detailState = .staleCache(.artist(detail), Self.displayError(for: error))
        }
    }
}
