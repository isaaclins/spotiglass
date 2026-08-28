import Foundation

protocol SpotifyBrowsingCache {
    /// On-disk playlist list and its age; used to skip a redundant `me/playlists` round-trip when the cache is still fresh.
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)?
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]?
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]?
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    func invalidateTracks(playlistID: String) throws
    func loadLibraryContinuationIndex(now: Date, maxAge: TimeInterval) throws -> LibraryContinuationLibrary?
    func loadLibraryContinuationIndexIgnoringAge() throws -> LibraryContinuationLibrary?
    func saveLibraryContinuationIndex(_ library: LibraryContinuationLibrary, cachedAt: Date) throws
    func invalidateLibraryContinuationIndex() throws
}

extension SpotifyBrowsingCache {
    func loadLibraryContinuationIndex(now _: Date, maxAge _: TimeInterval) throws -> LibraryContinuationLibrary? { nil }
    func loadLibraryContinuationIndexIgnoringAge() throws -> LibraryContinuationLibrary? { nil }
    func saveLibraryContinuationIndex(_: LibraryContinuationLibrary, cachedAt _: Date) throws {}
    func invalidateLibraryContinuationIndex() throws {}
}

extension SpotifyLocalCache: SpotifyBrowsingCache {}
