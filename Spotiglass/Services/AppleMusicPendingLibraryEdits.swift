import Foundation

/// Library edits made from Spotiglass that the library on this Mac does not show yet.
///
/// An edit reaches the user's iCloud Music Library right away, but `MusicLibraryRequest` reads a
/// copy of the library on this Mac that catches up minutes later. Until it does, the provider
/// lays these edits over its reads, so the browser shows the change at once and keeps showing it
/// after a reload. Each entry ends when a read shows the change, or after `maxAge` at the latest.
///
/// One instance is shared by every Apple Music provider in the app (the browser and the search
/// view each have one). It lives in memory only, bounded by `maxEntries` per kind.
final class AppleMusicPendingLibraryEdits: @unchecked Sendable {
    static let shared = AppleMusicPendingLibraryEdits()
    /// The library on this Mac took more than half an hour to show a playlist created through
    /// the API in testing (macOS 27), so entries live for a working day.
    static let maxAge: TimeInterval = 12 * 60 * 60
    static let maxEntries = 500

    private struct SavedSong {
        /// `nil` when the song's details could not be loaded: it still counts as saved, it just
        /// can't be listed until the library shows it.
        let track: MusicTrack?
        let keys: Set<String>
        let at: Date
        /// For a playlist addition: how often the playlist lists the song once the library has
        /// it. A read showing fewer still needs this addition laid over it.
        var expectedOccurrences = 1
    }

    private struct PlaylistRemoval {
        let keys: Set<String>
        /// Title and artist, so adding the song back from elsewhere (under another ID) finds it.
        let metadataKey: String?
        /// How many occurrences of the song the playlist keeps after the edit.
        var expectedRemaining: Int
        let at: Date
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date

    private var savedSongs: [SavedSong] = []
    private var removedSongs: [Set<String>: Date] = [:]
    private var savedAlbums: [String: Date] = [:]
    private var removedAlbums: [String: Date] = [:]
    private var createdPlaylists: [(summary: MusicPlaylistSummary, existingIDsWithSameName: Set<String>, at: Date)] = []
    private var renamedPlaylists: [String: (name: String, at: Date)] = [:]
    private var deletedPlaylists: [String: Date] = [:]
    /// Cloud library IDs (`p.…`) learned for library playlists, by the playlist's MusicKit ID.
    private var cloudPlaylistIDs: [String: (cloudID: String, at: Date)] = [:]
    private var playlistAdditions: [String: [SavedSong]] = [:]
    private var playlistRemovals: [String: [PlaylistRemoval]] = [:]

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Recording

    func recordSavedSong(_ track: MusicTrack?, reference: AppleMusicSongReference) {
        locked {
            let keys = reference.matchKeys.union(track.map { [$0.id, Self.metadataKey($0)] } ?? [])
            removedSongs = removedSongs.filter { $0.key.isDisjoint(with: keys) }
            savedSongs.removeAll { !$0.keys.isDisjoint(with: keys) }
            savedSongs.insert(SavedSong(track: track, keys: keys, at: now()), at: 0)
            savedSongs = Array(savedSongs.prefix(Self.maxEntries))
        }
    }

    func recordRemovedSong(_ keys: Set<String>) {
        locked {
            savedSongs.removeAll { !$0.keys.isDisjoint(with: keys) }
            removedSongs[keys] = now()
            trim(&removedSongs)
        }
    }

    func forgetRemovedSong(_ keys: Set<String>) {
        locked { removedSongs = removedSongs.filter { $0.key.isDisjoint(with: keys) } }
    }

    func recordSavedAlbum(_ id: String) {
        locked {
            removedAlbums[id] = nil
            savedAlbums[id] = now()
            trim(&savedAlbums)
        }
    }

    func recordRemovedAlbum(_ id: String) {
        locked {
            savedAlbums[id] = nil
            removedAlbums[id] = now()
            trim(&removedAlbums)
        }
    }

    /// `existingIDsWithSameName`: playlists that already had this name, which don't count as
    /// the library showing the new one.
    func recordCreatedPlaylist(_ summary: MusicPlaylistSummary, existingIDsWithSameName: Set<String> = []) {
        locked {
            createdPlaylists.removeAll { $0.summary.id == summary.id }
            createdPlaylists.insert((summary, existingIDsWithSameName, now()), at: 0)
            createdPlaylists = Array(createdPlaylists.prefix(Self.maxEntries))
        }
    }

    func recordRenamedPlaylist(_ id: String, name: String) {
        locked {
            if let index = createdPlaylists.firstIndex(where: { $0.summary.id == id }) {
                createdPlaylists[index].summary = createdPlaylists[index].summary.renamed(name)
            }
            renamedPlaylists[id] = (name, now())
            if renamedPlaylists.count > Self.maxEntries, let oldest = renamedPlaylists.min(by: { $0.value.at < $1.value.at }) {
                renamedPlaylists[oldest.key] = nil
            }
        }
    }

    func recordCloudPlaylistID(_ cloudID: String, for playlistID: String) {
        locked {
            cloudPlaylistIDs[playlistID] = (cloudID, now())
            if cloudPlaylistIDs.count > Self.maxEntries, let oldest = cloudPlaylistIDs.min(by: { $0.value.at < $1.value.at }) {
                cloudPlaylistIDs[oldest.key] = nil
            }
        }
    }

    func recordDeletedPlaylist(_ id: String) {
        locked {
            cloudPlaylistIDs[id] = nil
            createdPlaylists.removeAll { $0.summary.id == id }
            renamedPlaylists[id] = nil
            playlistAdditions[id] = nil
            playlistRemovals[id] = nil
            deletedPlaylists[id] = now()
            trim(&deletedPlaylists)
        }
    }

    /// `shownBefore` is how often the playlist listed the song before this addition.
    func recordPlaylistAddition(
        _ track: MusicTrack,
        reference: AppleMusicSongReference,
        playlistID: String,
        shownBefore: Int = 0
    ) {
        locked {
            let keys = reference.matchKeys.union([track.id, Self.metadataKey(track)])
            // Adding back a song removed moments ago: the playlist keeps one more copy than the
            // removal expected, which a read can't tell from the old copy. One count, not two edits.
            if var removals = playlistRemovals[playlistID], let index = removals.firstIndex(where: { removal in
                !removal.keys.isDisjoint(with: keys) || removal.metadataKey == Self.metadataKey(track)
            }) {
                removals[index].expectedRemaining += 1
                playlistRemovals[playlistID] = removals
                return
            }
            var additions = playlistAdditions[playlistID] ?? []
            additions.append(SavedSong(
                track: track,
                keys: keys,
                at: now(),
                expectedOccurrences: max(0, shownBefore) + 1
            ))
            playlistAdditions[playlistID] = Array(additions.suffix(Self.maxEntries))
        }
    }

    /// `shownBefore` is how often the playlist listed the song before the edit (pending
    /// additions included), `removed` how many of those the edit took out.
    func recordPlaylistRemoval(
        _ keys: Set<String>,
        metadataKey: String? = nil,
        removed: Int,
        shownBefore: Int,
        playlistID: String
    ) {
        guard removed > 0 else { return }
        locked {
            var remaining = removed
            var shown = shownBefore
            // Songs added from Spotiglass and removed again before the library has them only
            // undo the pending addition.
            if var additions = playlistAdditions[playlistID] {
                while remaining > 0, let index = additions.lastIndex(where: { !$0.keys.isDisjoint(with: keys) }) {
                    additions.remove(at: index)
                    remaining -= 1
                    shown -= 1
                }
                playlistAdditions[playlistID] = additions.isEmpty ? nil : additions
            }
            guard remaining > 0 else { return }
            var removals = (playlistRemovals[playlistID] ?? []).filter { $0.keys.isDisjoint(with: keys) }
            removals.append(PlaylistRemoval(
                keys: keys,
                metadataKey: metadataKey,
                expectedRemaining: max(0, shown - remaining),
                at: now()
            ))
            playlistRemovals[playlistID] = Array(removals.suffix(Self.maxEntries))
        }
    }

    // MARK: - Questions

    func isSaved(_ keys: Set<String>) -> Bool {
        locked {
            expire()
            return savedSongs.contains { !$0.keys.isDisjoint(with: keys) }
        }
    }

    func isRemoved(_ keys: Set<String>) -> Bool {
        locked {
            expire()
            return removedSongs.keys.contains { !$0.isDisjoint(with: keys) }
        }
    }

    /// The pending save for these keys, with when it was made.
    func savedSong(matching keys: Set<String>) -> (track: MusicTrack?, at: Date)? {
        locked {
            expire()
            return savedSongs.first { !$0.keys.isDisjoint(with: keys) }.map { ($0.track, $0.at) }
        }
    }

    func isSavedAlbum(_ id: String) -> Bool {
        locked {
            expire()
            return savedAlbums[id] != nil
        }
    }

    func isRemovedAlbum(_ id: String) -> Bool {
        locked {
            expire()
            return removedAlbums[id] != nil
        }
    }

    func renamedName(for playlistID: String) -> String? {
        locked {
            expire()
            return renamedPlaylists[playlistID]?.name
        }
    }

    func cloudPlaylistID(for playlistID: String) -> String? {
        locked {
            expire()
            return cloudPlaylistIDs[playlistID]?.cloudID
        }
    }

    /// The playlists that already had the name when this one was created.
    func existingIDsWithSameName(asCreated id: String) -> Set<String> {
        locked {
            expire()
            return createdPlaylists.first { $0.summary.id == id }?.existingIDsWithSameName ?? []
        }
    }

    func createdPlaylist(id: String) -> MusicPlaylistSummary? {
        locked {
            expire()
            return createdPlaylists.first { $0.summary.id == id }?.summary
        }
    }

    // MARK: - Laying edits over reads

    /// Liked Songs: library songs (with every ID each is known by), newest first. Pending saves
    /// go on top, pending removals are left out. `isComplete` says the read covered the whole
    /// library, so a removal it no longer shows has reached it.
    func applied(toLibrarySongs songs: [(track: MusicTrack, keys: Set<String>)], isComplete: Bool) -> [MusicTrack] {
        locked {
            expire()
            let shownKeys = songs.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
            savedSongs.removeAll { !$0.keys.isDisjoint(with: shownKeys) }
            if isComplete {
                removedSongs = removedSongs.filter { !$0.key.isDisjoint(with: shownKeys) }
            }
            let kept = songs.filter { song in
                !removedSongs.keys.contains { !$0.isDisjoint(with: song.keys) }
            }
            return savedSongs.compactMap(\.track) + kept.map(\.track)
        }
    }

    /// Library playlists: created ones on top until a new playlist with the same name shows up
    /// (one that didn't have the name before), renamed ones under their new name, deleted ones
    /// left out.
    func applied(toPlaylists playlists: [MusicPlaylistSummary]) -> [MusicPlaylistSummary] {
        locked {
            expire()
            let shownIDs = Set(playlists.map(\.id))
            deletedPlaylists = deletedPlaylists.filter { shownIDs.contains($0.key) }
            createdPlaylists.removeAll { created in
                shownIDs.contains(created.summary.id) || playlists.contains { playlist in
                    playlist.name == created.summary.name && !created.existingIDsWithSameName.contains(playlist.id)
                }
            }
            for playlist in playlists where renamedPlaylists[playlist.id]?.name == playlist.name {
                renamedPlaylists[playlist.id] = nil
            }
            let shown = playlists
                .filter { deletedPlaylists[$0.id] == nil }
                .map { playlist in renamedPlaylists[playlist.id].map { playlist.renamed($0.name) } ?? playlist }
            return createdPlaylists.map(\.summary) + shown
        }
    }

    /// One playlist's tracks: songs added from Spotiglass at the end, removed occurrences left out.
    func applied(toPlaylistTracks tracks: [(track: MusicTrack, keys: Set<String>)], playlistID: String) -> [MusicTrack] {
        locked {
            expire()
            var result = tracks
            if var removals = playlistRemovals[playlistID] {
                removals.removeAll { removal in
                    let occurrences = result.indices.filter { !result[$0].keys.isDisjoint(with: removal.keys) }
                    // The library shows the removal: nothing left to lay over it.
                    guard occurrences.count > removal.expectedRemaining else { return true }
                    for position in occurrences.suffix(occurrences.count - removal.expectedRemaining).reversed() {
                        result.remove(at: position)
                    }
                    return false
                }
                playlistRemovals[playlistID] = removals.isEmpty ? nil : removals
            }
            if var additions = playlistAdditions[playlistID] {
                // An addition ends once the read lists the song as often as the addition expects.
                additions.removeAll { addition in
                    tracks.filter { !$0.keys.isDisjoint(with: addition.keys) }.count >= addition.expectedOccurrences
                }
                playlistAdditions[playlistID] = additions.isEmpty ? nil : additions
                return result.map(\.track) + additions.compactMap(\.track)
            }
            return result.map(\.track)
        }
    }

    /// True when `playlistID` has edits a read of its tracks has to account for.
    func hasPendingTracks(playlistID: String) -> Bool {
        locked {
            expire()
            return playlistAdditions[playlistID] != nil || playlistRemovals[playlistID] != nil
        }
    }

    /// True when Liked Songs has edits a read has to account for.
    var hasPendingSongs: Bool {
        locked {
            expire()
            return !savedSongs.isEmpty || !removedSongs.isEmpty
        }
    }

    // MARK: - Helpers

    /// Title and first artist, as a last way to recognise a saved or added song in a read: the
    /// library may list it under an ID this Mac learns only later (a playlist entry's persistent
    /// ID, or a new cloud library ID). Only ever used to end a pending edit, never to change one.
    static func metadataKey(_ track: MusicTrack) -> String {
        metadataKey(name: track.name, artist: track.artists.first)
    }

    static func metadataKey(name: String, artist: String?) -> String {
        "meta:\(name.lowercased())|\((artist ?? "").lowercased())"
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func expire() {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        savedSongs.removeAll { $0.at < cutoff }
        removedSongs = removedSongs.filter { $0.value >= cutoff }
        savedAlbums = savedAlbums.filter { $0.value >= cutoff }
        removedAlbums = removedAlbums.filter { $0.value >= cutoff }
        createdPlaylists.removeAll { $0.at < cutoff }
        renamedPlaylists = renamedPlaylists.filter { $0.value.at >= cutoff }
        deletedPlaylists = deletedPlaylists.filter { $0.value >= cutoff }
        cloudPlaylistIDs = cloudPlaylistIDs.filter { $0.value.at >= cutoff }
        playlistAdditions = playlistAdditions.compactMapValues { additions in
            let kept = additions.filter { $0.at >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        playlistRemovals = playlistRemovals.compactMapValues { removals in
            let kept = removals.filter { $0.at >= cutoff }
            return kept.isEmpty ? nil : kept
        }
    }

    private func trim<Key>(_ entries: inout [Key: Date]) {
        guard entries.count > Self.maxEntries else { return }
        for (key, _) in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - Self.maxEntries) {
            entries[key] = nil
        }
    }
}

extension MusicPlaylistSummary {
    func renamed(_ name: String) -> MusicPlaylistSummary {
        MusicPlaylistSummary(
            id: id,
            name: name,
            ownerID: ownerID,
            ownerName: ownerName,
            imageURL: imageURL,
            trackCount: trackCount,
            snapshotID: snapshotID
        )
    }
}
