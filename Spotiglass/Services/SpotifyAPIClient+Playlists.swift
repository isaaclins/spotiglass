import Foundation

extension SpotifyAPIClient {
    /// Renames a playlist owned by the current user.
    func updatePlaylist(playlistID: String, name: String) async throws {
        guard !playlistID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist ID is required.")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist name is required.")
        }
        try await sendVoidWrite(
            method: "PUT",
            path: "/v1/playlists/\(playlistID)",
            queryItems: [],
            jsonBody: ["name": trimmedName]
        )
    }

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
