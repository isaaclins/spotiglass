import Foundation

extension SpotifyAPIClient {
    func search(query: String, limit: Int = 6) async throws -> SpotifySearchResults {
        try await search(query: query, limit: limit, offset: 0)
    }

    /// Paged catalog search. `offset` is the only way past the first 10 results per
    /// item type: `limit` is capped at 10 by Spotify, not by us.
    func search(query: String, limit: Int, offset: Int) async throws -> SpotifySearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        /// `GET /v1/search` documents `limit` range **0–10** per returned item type (not 50).
        let cappedLimit = min(max(1, limit), 10)
        var queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "track,artist,album,playlist"),
            URLQueryItem(name: "limit", value: String(cappedLimit))
        ]
        if offset > 0 {
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        let dto: SpotifySearchResponseDTO = try await send(
            path: "/v1/search",
            queryItems: queryItems
        )
        return dto.domainModel()
    }

    /// Track-only search (`GET /v1/search` with `type=track`). `limit` is capped at **10** per Spotify’s search endpoint.
    func searchTracks(query: String, limit: Int = 50) async throws -> [SpotifyTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let capped = min(max(1, limit), 10)
        let dto: SpotifySearchResponseDTO = try await send(
            path: "/v1/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: String(capped))
            ]
        )
        return dto.domainModel().tracks
    }
}
