import Foundation
import MusicKit

/// Library edits for the Apple Music provider. `AppleMusicLibraryEditor` decides the route for
/// each one; this maps the browser's calls onto it.
///
/// Liked Songs are the songs in the library (see `AppleMusicBrowsingProvider`), so a like saves a
/// song to the library and an unlike removes it from there.
extension AppleMusicBrowsingProvider {
    var supportedLibraryEdits: MusicLibraryEdits { .all }

    func saveTracks(ids: [String]) async throws {
        try await editor.saveSongs(ids: ids)
    }

    func removeSavedTracks(ids: [String]) async throws {
        try await editor.removeSongs(ids: ids)
        // Music takes the songs out of every playlist they were in, and which ones that are is
        // not known here.
        await trackCountCache.forgetAll()
    }

    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        try await editor.songStatuses(ids: ids)
    }

    func saveAlbums(ids: [String]) async throws {
        try await editor.saveAlbums(ids: ids)
    }

    func removeSavedAlbums(ids: [String]) async throws {
        try await editor.removeAlbums(ids: ids)
        await trackCountCache.forgetAll()
    }

    func savedAlbumStatuses(ids: [String]) async throws -> [Bool] {
        try await editor.albumStatuses(ids: ids)
    }

    /// Apple Music playlists have no owner to pass and are always private to the library.
    func createPlaylist(userID: String, name: String, isPublic: Bool) async throws -> MusicPlaylistSummary {
        try await createPlaylist(userID: userID, name: name, isPublic: isPublic, trackURIs: [])
    }

    /// The songs go in with the create itself, so a song that can't be added leaves no empty
    /// playlist behind (#395).
    func createPlaylist(userID: String, name: String, isPublic: Bool, trackURIs: [String]) async throws -> MusicPlaylistSummary {
        let songIDs = trackURIs.compactMap(AppleMusicItemMapping.songID(fromURI:))
        guard songIDs.count == trackURIs.count else { throw AppleMusicLibraryEditError.notEditable }
        // Playlists that already have this name don't count as the library showing the new one.
        let existing = (try? await libraryPlaylists(limit: 100)) ?? []
        return try await editor.createPlaylist(
            name: name,
            ownerName: SpotiglassL10n.string("appleMusic.library.owner"),
            songIDs: songIDs,
            existingIDsWithSameName: Set(existing.filter { AppleMusicLibraryEditor.isSamePlaylistName($0.nameAsSent, name) }.map(\.id))
        )
    }

    func knownSavedTrackStatus(id: String) -> Bool? {
        editor.knownSongStatus(id: id)
    }

    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        let ids = uris.compactMap(AppleMusicItemMapping.songID(fromURI:))
        guard !ids.isEmpty else { throw AppleMusicLibraryEditError.notEditable }
        // Reading a long destination remembers its rows too, which can push the rows being
        // added out of the bounded registry; they come back after the read.
        let adding = ids.compactMap(editor.songReferences.reference(for:))
        // The playlist as shown now, so a second copy of a song it has stays shown until the
        // library lists both.
        let shown = (try? await playlistTracks(playlistID: playlistID, limit: 100, maxPages: 100)) ?? []
        adding.forEach(editor.songReferences.remember)
        let shownTracks = shown.compactMap { item -> MusicTrack? in
            if case let .track(track) = item.content { return track }
            return nil
        }
        try await editor.addToPlaylist(playlistID: playlistID, songIDs: ids, shownTracks: shownTracks)
        await trackCountCache.forget([playlistID])
    }

    /// `snapshotID` is Spotify's; Apple Music has none.
    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws {
        let removals = items.compactMap { item in
            AppleMusicItemMapping.songID(fromURI: item.uri).map { (songID: $0, positions: item.positions) }
        }
        guard !removals.isEmpty else { throw AppleMusicLibraryEditError.notEditable }
        // The playlist as shown now, so the pending edit knows which copies were picked and
        // when the library shows the removal.
        let shown = (try? await playlistTracks(playlistID: playlistID, limit: 100, maxPages: 100)) ?? []
        let shownTracks = shown.compactMap { item -> MusicTrack? in
            if case let .track(track) = item.content { return track }
            return nil
        }
        try await editor.removeFromPlaylist(playlistID: playlistID, removals: removals, shownTracks: shownTracks)
        await trackCountCache.forget([playlistID])
    }

    /// `snapshotID` is Spotify's; Apple Music has none, so this returns none.
    func reorderPlaylistTracks(
        playlistID: String,
        reorder: MusicPlaylistReorder,
        snapshotID: String?
    ) async throws -> String? {
        // The songs read for counting are in the old order; opening the playlist again showed
        // them first. A save that failed partway changed the order too, so they go either way.
        do {
            try await editor.reorderPlaylist(playlistID: playlistID, reorder: reorder)
        } catch {
            await trackCountCache.forget([playlistID])
            throw error
        }
        await trackCountCache.forget([playlistID])
        return nil
    }

    func updatePlaylist(playlistID: String, name: String) async throws {
        try await editor.renamePlaylist(playlistID: playlistID, name: name)
    }

    func deletePlaylist(playlistID: String) async throws {
        try await editor.deletePlaylist(playlistID: playlistID)
    }

    // MARK: - Pending edits over reads

    func applyingPendingEdits(toLibrarySongs songs: [Song], isComplete: Bool) -> [MusicTrack] {
        guard editor.pending.hasPendingSongs else { return songs.map(AppleMusicItemMapping.track) }
        let identified = songs.map { song in
            Self.identified(song)
        }
        return editor.pending.applied(toLibrarySongs: identified, isComplete: isComplete)
    }

    /// `isComplete` is false when the read stopped at its limit.
    func applyingPendingEdits(toPlaylistTracks tracks: [Track], playlistID: String, isComplete: Bool = true) -> [MusicTrack] {
        editor.songReferences.remember(tracks, playlistID: playlistID)
        // Removing a song from the library also takes it out of every playlist.
        guard editor.pending.laysEditsOver(playlistID: playlistID) || editor.pending.hasPendingSongs else {
            return tracks.map { AppleMusicItemMapping.track($0) }
        }
        let identified = tracks.map { track -> (track: MusicTrack, keys: Set<String>) in
            if case let .song(song) = track { return Self.identified(song) }
            let mapped = AppleMusicItemMapping.track(track)
            return (mapped, [track.id.rawValue, AppleMusicPendingLibraryEdits.metadataKey(mapped)])
        }
        return editor.pending.applied(toPlaylistTracks: identified, playlistID: playlistID, isComplete: isComplete)
    }

    /// Each playlist's count, leaving out the songs removed from the library from Spotiglass
    /// that the library still lists, as the open playlist leaves them out. Empty playlists have
    /// no count.
    func countsLeavingOutRemovedSongs(_ tracksByPlaylistID: [String: [Track]]) -> [String: Int] {
        guard editor.pending.hasRemovedSongs else {
            return tracksByPlaylistID.compactMapValues { $0.isEmpty ? nil : $0.count }
        }
        return tracksByPlaylistID.compactMapValues { tracks in
            let count = editor.pending.countNotRemoved(tracks.map(Self.pendingKeys))
            return count > 0 ? count : nil
        }
    }

    /// Every key a pending edit may know a track by.
    private static func pendingKeys(_ track: Track) -> Set<String> {
        if case let .song(song) = track { return identified(song).keys }
        return [track.id.rawValue, AppleMusicPendingLibraryEdits.metadataKey(AppleMusicItemMapping.track(track))]
    }

    /// A song with every key a pending edit may know it by.
    private static func identified(_ song: Song) -> (track: MusicTrack, keys: Set<String>) {
        let track = AppleMusicItemMapping.track(song)
        let keys = AppleMusicSongIdentity(encoding: song).keys(itemID: song.id.rawValue)
            .union([AppleMusicPendingLibraryEdits.metadataKey(track)])
        return (track, keys)
    }

    /// Tracks of a playlist created through Apple Music that the library on this Mac does not
    /// show yet, with this session's edits on top.
    func pendingPlaylistTracks(playlistID: String) async throws -> [MusicTrack]? {
        guard let songs = try await editor.cloudPlaylistTracks(playlistID: playlistID) else { return nil }
        let identified = songs.map { song in
            Self.identified(song)
        }
        return editor.pending.applied(toPlaylistTracks: identified, playlistID: playlistID)
    }
}

extension AppleMusicItemMapping {
    /// The song ID inside an `applemusic:song:<id>` URI.
    static func songID(fromURI uri: String) -> String? {
        let prefix = "\(uriScheme):song:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
