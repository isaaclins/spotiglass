import Foundation

extension SpotifyAPIClient {
    /// Recently played tracks (`GET /v1/me/player/recently-played`). Requires the
    /// `user-read-recently-played` scope. Tracks are de-duplicated by id, keeping the
    /// most-recent play, so the home carousel never shows the same song twice in a row.
    func recentlyPlayedTracks(limit: Int = 50) async throws -> [SpotifyTrack] {
        let pageLimit = min(max(1, limit), 50)
        let response: SpotifyRecentlyPlayedResponseDTO = try await send(
            path: "/v1/me/player/recently-played",
            queryItems: [URLQueryItem(name: "limit", value: String(pageLimit))],
            cacheMode: .freshOnly
        )
        var seen: Set<String> = []
        var tracks: [SpotifyTrack] = []
        for item in response.items {
            guard let track = item.track?.domainModel() else { continue }
            guard seen.insert(track.id).inserted else { continue }
            tracks.append(track)
        }
        return tracks
    }

    /// The signed-in user's top tracks (`GET /v1/me/top/tracks`). Requires the
    /// `user-top-read` scope. `timeRange` is one of `short_term`, `medium_term`,
    /// `long_term`.
    func topTracks(limit: Int = 20, timeRange: String = "short_term") async throws -> [SpotifyTrack] {
        let pageLimit = min(max(1, limit), 50)
        let page: SpotifyPagingDTO<SpotifyTrackDTO> = try await send(
            path: "/v1/me/top/tracks",
            queryItems: [
                URLQueryItem(name: "limit", value: String(pageLimit)),
                URLQueryItem(name: "time_range", value: timeRange),
            ],
            cacheMode: .freshOnly
        )
        return page.items.compactMap { $0.domainModel() }
    }
}
