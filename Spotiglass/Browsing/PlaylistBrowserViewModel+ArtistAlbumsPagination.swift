import Foundation

extension PlaylistBrowserViewModel {
    func loadMoreArtistAlbums() async {
        guard case let .loaded(.artist(detail)) = detailState,
              var paging = currentArtistAlbumsPaging,
              paging.artistID == detail.artist.id,
              !paging.isLoading,
              let nextURL = paging.nextURL else {
            return
        }
        let session = detailSession
        let artistID = detail.artist.id

        paging.isLoading = true
        currentArtistAlbumsPaging = paging
        detailState = .loaded(.artist(
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
                guard ownsArtistPagination(session: session, artistID: artistID) else { return }
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
            cachedArtistSnapshots[artistID] = CachedArtistSnapshot(
                snapshot: ArtistDetailSnapshot(
                    artistDetail: detail.artist,
                    albums: paging.albums,
                    tracks: paging.tracks,
                    usedStaleCache: false,
                    paging: paging
                ),
                fetchedAt: now()
            )
            guard ownsArtistDetailSurface(session: session, artistID: artistID) else { return }
            detailState = .loaded(.artist(refreshed))
        } catch {
            guard ownsArtistPagination(session: session, artistID: artistID) else { return }
            paging.isLoading = false
            currentArtistAlbumsPaging = paging
            guard ownsArtistDetailSurface(session: session, artistID: artistID) else { return }
            detailState = .staleCache(.artist(detail), Self.displayError(for: error))
        }
    }

    private func ownsArtistPagination(session: Int, artistID: String) -> Bool {
        session == detailSession && currentArtistAlbumsPaging?.artistID == artistID
    }

    private func ownsArtistDetailSurface(session: Int, artistID: String) -> Bool {
        guard ownsArtistPagination(session: session, artistID: artistID),
              case let .loaded(.artist(detail)) = detailState else {
            return false
        }
        return detail.artist.id == artistID
    }
}
