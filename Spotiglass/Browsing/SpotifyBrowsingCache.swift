import Foundation

protocol SpotifyBrowsingCache {
    /// On-disk playlist list and its age; used to skip a redundant `me/playlists` round-trip when the cache is still fresh.
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [MusicPlaylistSummary], age: TimeInterval)?
    func savePlaylists(_ playlists: [MusicPlaylistSummary], cachedAt: Date) throws
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [MusicPlaylistTrackItem]?
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [MusicPlaylistTrackItem]?
    func saveTracks(_ tracks: [MusicPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
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

/// Track lists kept in memory for this session only, for a service whose rows can't outlive it.
///
/// Apple Music's library artwork and playable songs are only valid while MusicKit's session
/// lives, so a disk copy would show blank covers and rows that don't play. Without any copy,
/// though, reopening a playlist read it again every time (#442). Bounded to `maxTracks` over all
/// playlists, least recently used first out; the playlist list is not kept.
final class MemoryBrowsingCache: SpotifyBrowsingCache, @unchecked Sendable {
    static let maxTracks = 20_000

    private struct Entry {
        let tracks: CachedPlaylistTracks
        var usedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maxTracks: Int

    init(maxTracks: Int = MemoryBrowsingCache.maxTracks) {
        self.maxTracks = maxTracks
    }

    func loadPlaylistsBundle(now: Date) throws -> (playlists: [MusicPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [MusicPlaylistSummary], cachedAt: Date) throws {}

    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [MusicPlaylistTrackItem]? {
        lock.withLock {
            guard var entry = entries[playlistID],
                  entry.tracks.isValid(forPlaylist: playlistID, snapshotID: snapshotID, now: now, maxAge: maxAge) else { return nil }
            entry.usedAt = Date()
            entries[playlistID] = entry
            return entry.tracks.tracks
        }
    }

    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [MusicPlaylistTrackItem]? {
        lock.withLock {
            guard var entry = entries[playlistID], entry.tracks.snapshotID == snapshotID else { return nil }
            entry.usedAt = Date()
            entries[playlistID] = entry
            return entry.tracks.tracks
        }
    }

    func saveTracks(_ tracks: [MusicPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        lock.withLock {
            entries[playlistID] = Entry(
                tracks: CachedPlaylistTracks(playlistID: playlistID, snapshotID: snapshotID, tracks: tracks, cachedAt: cachedAt),
                usedAt: Date()
            )
            var total = entries.values.reduce(0) { $0 + $1.tracks.tracks.count }
            while total > maxTracks, entries.count > 1,
                  let oldest = entries.filter({ $0.key != playlistID }).min(by: { $0.value.usedAt < $1.value.usedAt }) {
                total -= oldest.value.tracks.tracks.count
                entries[oldest.key] = nil
            }
        }
    }

    func invalidateTracks(playlistID: String) throws {
        lock.withLock { entries[playlistID] = nil }
    }
}
