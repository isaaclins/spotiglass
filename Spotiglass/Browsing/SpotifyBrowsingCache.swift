import Foundation

protocol SpotifyBrowsingCache {
    /// On-disk playlist list and its age; used to skip a redundant `me/playlists` round-trip when the cache is still fresh.
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)?
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws
        -> [SpotifyPlaylistTrackItem]?
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]?
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    func invalidateTracks(playlistID: String) throws
}

extension SpotifyLocalCache: SpotifyBrowsingCache {}
