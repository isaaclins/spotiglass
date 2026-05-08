import Foundation

extension SpotifyAPIClient {
    func currentUserProfile() async throws -> SpotifyUserProfile {
        let dto: SpotifyUserProfileDTO = try await send(path: "/v1/me")
        return dto.domainModel()
    }

    func currentUserPlaylists(limit: Int = 50) async throws -> [SpotifyPlaylistSummary] {
        // `/v1/me/playlists` can span many pages; cap total pages to avoid
        // pathological loops and runaway request bursts if `next` misbehaves.
        try await collectPaged(path: "/v1/me/playlists", limit: limit, maxPages: 20) { (dto: SpotifyPlaylistDTO, _) in
            dto.domainModel()
        }
    }

    /// Liked Songs (`GET /v1/me/tracks`). Paginates with the same item shape as playlist tracks; stops after `maxPages` to avoid unbounded requests.
    func currentUserSavedTracks(limit: Int = 50, maxPages: Int = 20) async throws -> SpotifySavedTracksResult {
        let pageLimit = min(max(1, limit), 50)
        let maxPages = max(1, maxPages)
        var results: [SpotifyPlaylistTrackItem] = []
        var nextURL: URL?
        var offset = 0
        var totalAvailable = 0
        var pagesFetched = 0
        var seenOffsets: Set<Int> = [offset]

        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<SpotifyPlaylistTrackItemDTO>
            if let nextURL {
                if let nextOffset = Self.offset(from: nextURL),
                   seenOffsets.contains(nextOffset) {
                    break
                }
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
            seenOffsets.insert(page.offset)
            nextURL = page.next
            offset += page.limit
            pagesFetched += 1
            if pagesFetched >= maxPages {
                break
            }
        } while nextURL != nil

        return SpotifySavedTracksResult(tracks: results, totalAvailable: totalAvailable)
    }
}

private extension SpotifyAPIClient {
    static func offset(from url: URL) -> Int? {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offsetValue = queryItems.first(where: { $0.name == "offset" })?.value else {
            return nil
        }
        return Int(offsetValue)
    }
}
