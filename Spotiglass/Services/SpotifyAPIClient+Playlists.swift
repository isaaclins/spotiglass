import Foundation

extension SpotifyAPIClient {
    func playlistTracks(playlistID: String, limit: Int = 50, maxPages: Int = 200) async throws -> [SpotifyPlaylistTrackItem] {
        guard !playlistID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist ID is required.")
        }
        let pageCap = max(1, maxPages)
        return try await collectPaged(path: "/v1/playlists/\(playlistID)/items", limit: limit, maxPages: pageCap) { (dto: SpotifyPlaylistTrackItemDTO, index) in
            dto.domainModel(position: index)
        }
    }
}
