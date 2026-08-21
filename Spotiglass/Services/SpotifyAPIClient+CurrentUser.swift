import Foundation

extension SpotifyAPIClient {
    func currentUserProfile() async throws -> SpotifyUserProfile {
        let dto: SpotifyUserProfileDTO = try await send(path: "/v1/me")
        return dto.domainModel()
    }

    func currentUserPlaylists(limit: Int = 50) async throws -> [SpotifyPlaylistSummary] {
        // Follow Spotify's continuation links to completion. `collectPaged` stops
        // when a continuation URL repeats, protecting against malformed loops
        // without silently dropping a valid long library.
        try await collectPaged(path: "/v1/me/playlists", limit: limit) { (dto: SpotifyPlaylistDTO, _) in
            dto.domainModel()
        }
    }

    /// Liked Songs (`GET /v1/me/tracks`). Follows Spotify's continuation links to
    /// completion unless an explicit page cap is supplied by a caller.
    func currentUserSavedTracks(limit: Int = 50, maxPages: Int? = nil) async throws -> SpotifySavedTracksResult {
        let pageLimit = min(max(1, limit), 50)
        let pageCap = maxPages.map { max(1, $0) }
        var results: [SpotifyPlaylistTrackItem] = []
        var nextURL: URL?
        var offset = 0
        var totalAvailable = 0
        var pagesFetched = 0
        var seenNextURLs: Set<String> = []

        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<SpotifyPlaylistTrackItemDTO>
            if let nextURL {
                page = try await send(url: nextURL)
            } else {
                page = try await send(
                    path: "/v1/me/tracks",
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(pageLimit)),
                        URLQueryItem(name: "offset", value: String(offset))
                    ]
                )
            }
            if pagesFetched == 0 {
                totalAvailable = page.total
            }
            let startIndex = results.count
            results.append(contentsOf: page.items.enumerated().map { index, item in
                item.domainModel(position: startIndex + index)
            })
            nextURL = page.next
            if let nextURL {
                let key = nextURL.absoluteString
                if seenNextURLs.contains(key) {
                    break
                }
                seenNextURLs.insert(key)
            }
            offset += page.limit
            pagesFetched += 1
            if let pageCap, pagesFetched >= pageCap {
                break
            }
        } while nextURL != nil

        return SpotifySavedTracksResult(tracks: results, totalAvailable: totalAvailable)
    }
}
