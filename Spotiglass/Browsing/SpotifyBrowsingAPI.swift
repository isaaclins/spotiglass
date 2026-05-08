import Foundation

protocol SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem]
    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult
    func currentUserProfile() async throws -> SpotifyUserProfile
    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail
    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail>
    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack]
    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]>
    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage
    func search(query: String, limit: Int) async throws -> SpotifySearchResults
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack]
    /// Single-page album tracks fetch for the artist fallback recovery path. Default-implemented
    /// against `albumTracks` for mocks; the live client overrides with a true `maxPages: 1` call so a
    /// recovery for one album never amplifies into multiple HTTP requests.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack]
    /// Batched `GET /v1/albums?ids=...` (max 20 IDs). Replaces the per-album loop in the artist
    /// fallback so one HTTP call retrieves up to 20 albums (each with their first 50-track page).
    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum]
}

extension SpotifyAPIClient: SpotifyBrowsingAPI {}

extension SpotifyBrowsingAPI {
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        try await albumTracks(albumID: albumID, market: market, limit: limit)
    }
}
