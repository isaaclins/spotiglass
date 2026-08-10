import Foundation

struct SpotifyRecommendationsResponseDTO: Decodable {
    let tracks: [SpotifyTrackDTO]
}

extension SpotifyAPIClient {
    /// Fetches recommendations from Spotify's Recommendations endpoint (`GET /v1/recommendations`).
    /// If the endpoint returns an error (e.g., 403/404 under dev-mode restrictions), a fallback
    /// catalog search is performed using artist / seed track metadata so radio playback always succeeds.
    func recommendations(
        seedTracks: [String] = [],
        seedArtists: [String] = [],
        seedArtistName: String? = nil,
        seedTrackName: String? = nil,
        limit: Int = 30
    ) async throws -> [SpotifyTrack] {
        let cappedLimit = min(max(1, limit), 50)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(cappedLimit))
        ]

        if !seedTracks.isEmpty {
            queryItems.append(URLQueryItem(name: "seed_tracks", value: seedTracks.joined(separator: ",")))
        }
        if !seedArtists.isEmpty {
            queryItems.append(URLQueryItem(name: "seed_artists", value: seedArtists.joined(separator: ",")))
        }

        if !seedTracks.isEmpty || !seedArtists.isEmpty {
            do {
                let dto: SpotifyRecommendationsResponseDTO = try await send(
                    path: "/v1/recommendations",
                    queryItems: queryItems
                )
                let tracks = dto.tracks.compactMap { $0.domainModel() }
                if !tracks.isEmpty {
                    return tracks
                }
            } catch {
                SpotiglassLog.info(
                    .api,
                    "GET /v1/recommendations failed (\(error.localizedDescription)), triggering fallback radio search")
            }
        }

        // Fallback radio generation: search catalog for similar tracks by artist/track name
        return try await fallbackRadioSearch(
            seedArtistID: seedArtists.first,
            seedArtistName: seedArtistName,
            seedTrackName: seedTrackName,
            limit: cappedLimit
        )
    }

    private func fallbackRadioSearch(
        seedArtistID: String?,
        seedArtistName: String?,
        seedTrackName: String?,
        limit: Int
    ) async throws -> [SpotifyTrack] {
        if let artistID = seedArtistID, !artistID.isEmpty {
            if let topTracks = try? await artistTopTracks(id: artistID, market: nil), !topTracks.isEmpty {
                return Array(topTracks.shuffled().prefix(limit))
            }
        }

        if let artistName = seedArtistName, !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searchResults = try await searchTracks(query: "artist:\(artistName)", limit: limit)
            if !searchResults.isEmpty {
                return Array(searchResults.shuffled().prefix(limit))
            }
        }

        if let trackName = seedTrackName, !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let searchResults = try await searchTracks(query: trackName, limit: limit)
            if !searchResults.isEmpty {
                return searchResults
            }
        }

        return []
    }
}
