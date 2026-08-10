import Foundation

extension PlaylistBrowserViewModel {
    func loadArtistDetailSnapshot(id: String, preferCached: Bool) async throws -> ArtistDetailSnapshot {
        if let inFlight = artistDetailLoadTasks[id] {
            artistFetchMetrics.coalescedRequests += 1
            return try await inFlight.value
        }
        artistFetchMetrics.requestStarts += 1
        let task = Task { [api] in
            let profile = try await api.currentUserProfile()
            let market = profile.country
            if preferCached {
                async let cachedDetail = api.artistCached(id: id, cacheMode: .allowStale)
                async let cachedAlbums = api.artistAlbumsCached(
                    id: id,
                    includeGroups: "album,single,compilation",
                    limit: 10,
                    cacheMode: .allowStale
                )
                let (detailHit, albumsHit) = try await (cachedDetail, cachedAlbums)
                let tracks = await self.resolveArtistTracks(
                    artistId: id,
                    artist: detailHit.value,
                    albums: albumsHit.value,
                    market: market
                )
                return ArtistDetailSnapshot(
                    artistDetail: detailHit.value,
                    albums: albumsHit.value,
                    tracks: tracks,
                    usedStaleCache: detailHit.isStale || albumsHit.isStale,
                    paging: nil
                )
            }
            let artistDetail = try await api.artist(id: id, cacheMode: .bypassCache)
            let includeGroups = "album,single,compilation"
            let limit = 10
            var nextURL: URL?
            var nextOffset = 0
            var pagesFetched = 0
            var seenNextURLs: Set<String> = []
            var albumList: [SpotifyArtistAlbum] = []
            repeat {
                if let url = nextURL {
                    let key = url.absoluteString
                    if seenNextURLs.contains(key) {
                        break
                    }
                    seenNextURLs.insert(key)
                }
                let page = try await api.artistAlbumsPage(
                    id: id,
                    includeGroups: includeGroups,
                    limit: limit,
                    offset: nextOffset,
                    nextURL: nextURL,
                    cacheMode: .bypassCache
                )
                albumList = Self.dedupeAlbums(albumList + page.items)
                pagesFetched += 1
                nextOffset += limit
                nextURL = page.next
            } while nextURL != nil && pagesFetched < self.initialArtistAlbumPageCount
            let resolved = await self.resolveArtistTracks(
                artistId: id, artist: artistDetail, albums: albumList, market: market)
            let paging = ArtistAlbumsPagingState(
                artistID: id,
                includeGroups: includeGroups,
                limit: limit,
                nextURL: nextURL,
                nextOffset: nextOffset,
                albums: albumList,
                tracks: resolved,
                isLoading: false,
                seenNextURLs: seenNextURLs
            )
            return ArtistDetailSnapshot(
                artistDetail: artistDetail,
                albums: albumList,
                tracks: resolved,
                usedStaleCache: false,
                paging: paging
            )
        }
        artistDetailLoadTasks[id] = task
        defer { artistDetailLoadTasks[id] = nil }
        return try await task.value
    }

    static func dedupeAlbums(_ albums: [SpotifyArtistAlbum]) -> [SpotifyArtistAlbum] {
        var deduped: [SpotifyArtistAlbum] = []
        var seenIDs: Set<String> = []
        deduped.reserveCapacity(albums.count)
        for album in albums {
            guard !seenIDs.contains(album.id) else { continue }
            seenIDs.insert(album.id)
            deduped.append(album)
        }
        return deduped
    }
}
