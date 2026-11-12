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
        /// When the save was sent, for a song saved to the library: Music's `date added` is later.
        var requestedAt: Date?
    }

    /// Every add and remove made from Spotiglass in one playlist that the library may not show
    /// yet, in order, over the playlist as it showed before the first of them (#393).
    ///
    /// The library on this Mac catches up in the order the edits were made, so each read lists
    /// the playlist as it was after some number of them (its step). A read is matched row by row
    /// to the first step it lists exactly and shown as the playlist after every edit. Whole rows,
    /// not counts per song, tell apart steps that list each song equally often in other places:
    /// a copy removed and added back moves to the end, and so do other songs' copies.
    private struct PlaylistEdits {
        /// A row of the playlist after some of the edits.
        enum Entry: Hashable {
            /// A row the playlist showed before the first edit, by its place then.
            case listed(Int)
            /// A copy added from Spotiglass, by its index in `additions`.
            case added(Int)
        }

        enum Edit {
            case add(Int)
            case remove(Entry)
        }

        struct Addition {
            let track: MusicTrack
            let keys: Set<String>
        }

        /// The rows' IDs as the playlist showed them before the first edit.
        let listed: [String]
        var additions: [Addition] = []
        var edits: [Edit] = []
        /// The earliest step a read may still show: the library never goes back past a step a
        /// read showed.
        var shownStep = 0
        var at: Date

        func entries(after steps: Int) -> [Entry] {
            var entries = listed.indices.map(Entry.listed)
            for edit in edits.prefix(steps) {
                apply(edit, to: &entries)
            }
            return entries
        }

        func apply(_ edit: Edit, to entries: inout [Entry]) {
            switch edit {
            case let .add(index): entries.append(.added(index))
            case let .remove(entry): entries.removeAll { $0 == entry }
            }
        }

        func keys(of entry: Entry) -> Set<String> {
            switch entry {
            case let .listed(index): [listed[index]]
            case let .added(index): additions[index].keys
            }
        }
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
    private var playlistEdits: [String: PlaylistEdits] = [:]

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Recording

    /// `requestedAt` is when the save request went out.
    func recordSavedSong(_ track: MusicTrack?, reference: AppleMusicSongReference, requestedAt: Date? = nil) {
        locked {
            let keys = reference.matchKeys.union(track.map { [$0.id, Self.metadataKey($0)] } ?? [])
            removedSongs = removedSongs.filter { $0.key.isDisjoint(with: keys) }
            savedSongs.removeAll { !$0.keys.isDisjoint(with: keys) }
            savedSongs.insert(SavedSong(track: track, keys: keys, at: now(), requestedAt: requestedAt), at: 0)
            savedSongs = Array(savedSongs.prefix(Self.maxEntries))
        }
    }

    /// A song removed from the library: Music also takes it out of every playlist, so pending
    /// playlist edits leave it out too.
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

    /// Keeps a created playlist's track count in step with songs added to or removed from it
    /// before the library lists it, so the sidebar doesn't show the count it was created with.
    func adjustCreatedPlaylistTrackCount(_ id: String, by delta: Int) {
        guard delta != 0 else { return }
        locked {
            guard let index = createdPlaylists.firstIndex(where: { $0.summary.id == id }) else { return }
            let summary = createdPlaylists[index].summary
            createdPlaylists[index].summary = summary.with(trackCount: max(0, (summary.trackCount ?? 0) + delta))
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
            playlistEdits[id] = nil
            deletedPlaylists[id] = now()
            trim(&deletedPlaylists)
        }
    }

    /// Records adding these songs at the end of a playlist. `shown` is the playlist as the
    /// browser showed it before the edit (pending edits included).
    func recordPlaylistAdditions(
        _ songs: [(track: MusicTrack, reference: AppleMusicSongReference)],
        playlistID: String,
        shown: [MusicTrack]
    ) {
        guard !songs.isEmpty else { return }
        locked {
            editPlaylist(playlistID, shown: shown) { playlist in
                for song in songs {
                    let keys = song.reference.matchKeys.union([song.track.id, Self.metadataKey(song.track)])
                    playlist.additions.append(.init(track: song.track, keys: keys))
                    playlist.edits.append(.add(playlist.additions.count - 1))
                }
            }
        }
    }

    /// Records removing the rows at `positions` of `shown`, the playlist as the browser showed
    /// it before the edit (pending edits included).
    func recordPlaylistRemoval(at positions: [Int], playlistID: String, shown: [MusicTrack]) {
        guard !positions.isEmpty else { return }
        locked {
            editPlaylist(playlistID, shown: shown) { playlist in
                let entries = visible(playlist.entries(after: playlist.edits.count), of: playlist)
                playlist.edits += Set(positions).filter(entries.indices.contains).sorted().map { .remove(entries[$0]) }
            }
        }
    }

    /// Adds edits to the playlist's record. The playlist as shown is its record after every
    /// edit; a record that doesn't list as many rows (the playlist changed elsewhere since)
    /// starts over from what is shown.
    private func editPlaylist(_ id: String, shown: [MusicTrack], _ edit: (inout PlaylistEdits) -> Void) {
        var playlist = playlistEdits[id].flatMap { playlist in
            visible(playlist.entries(after: playlist.edits.count), of: playlist).count == shown.count ? playlist : nil
        } ?? PlaylistEdits(listed: shown.map(\.id), at: now())
        playlist.at = now()
        edit(&playlist)
        playlistEdits[id] = playlist
        if playlistEdits.count > Self.maxEntries, let oldest = playlistEdits.min(by: { $0.value.at < $1.value.at }) {
            playlistEdits[oldest.key] = nil
        }
    }

    /// The entries a read lists: songs removed from the library leave every playlist.
    private func visible(_ entries: [PlaylistEdits.Entry], of playlist: PlaylistEdits) -> [PlaylistEdits.Entry] {
        entries.filter { entry in
            let keys = playlist.keys(of: entry)
            return !removedSongs.keys.contains { !$0.isDisjoint(with: keys) }
        }
    }

    // MARK: - Questions

    func isSaved(_ keys: Set<String>) -> Bool {
        locked {
            expire()
            return savedSongs.contains { !$0.keys.isDisjoint(with: keys) }
        }
    }

    /// How many of these tracks (each by its keys) are not removed from the library, in one go.
    func countNotRemoved(_ tracks: [Set<String>]) -> Int {
        locked {
            expire()
            return tracks.filter { keys in !removedSongs.keys.contains { !$0.isDisjoint(with: keys) } }.count
        }
    }

    func isRemoved(_ keys: Set<String>) -> Bool {
        locked {
            expire()
            return removedSongs.keys.contains { !$0.isDisjoint(with: keys) }
        }
    }

    /// The pending save for these keys, with when it was sent.
    func savedSong(matching keys: Set<String>) -> (track: MusicTrack?, at: Date)? {
        locked {
            expire()
            return savedSongs.first { !$0.keys.isDisjoint(with: keys) }.map { ($0.track, $0.requestedAt ?? $0.at) }
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
            // Names as sent, not the stand-in two different names may both show (#547).
            createdPlaylists.removeAll { created in
                shownIDs.contains(created.summary.id) || playlists.contains { playlist in
                    AppleMusicLibraryEditor.isSamePlaylistName(playlist.nameAsSent, created.summary.nameAsSent)
                        && !created.existingIDsWithSameName.contains(playlist.id)
                }
            }
            for playlist in playlists where renamedPlaylists[playlist.id]?.name == playlist.nameAsSent {
                renamedPlaylists[playlist.id] = nil
            }
            let shown = playlists
                .filter { deletedPlaylists[$0.id] == nil }
                .map { playlist in renamedPlaylists[playlist.id].map { playlist.renamed($0.name) } ?? playlist }
            return createdPlaylists.map(\.summary) + shown
        }
    }

    /// One playlist's tracks: songs added from Spotiglass at the end, removed copies left out,
    /// and songs removed from the library left out (Music takes them out of every playlist).
    func applied(toPlaylistTracks tracks: [(track: MusicTrack, keys: Set<String>)], playlistID: String) -> [MusicTrack] {
        locked {
            expire()
            let result = tracks.filter { track in
                !removedSongs.keys.contains { !$0.isDisjoint(with: track.keys) }
            }
            guard var playlist = playlistEdits[playlistID] else { return result.map(\.track) }
            let final = visible(playlist.entries(after: playlist.edits.count), of: playlist)
            // The first step from the last one a read showed that lists exactly these rows.
            var step = playlist.shownStep
            var entries = playlist.entries(after: step)
            var read = visible(entries, of: playlist)
            while !Self.lists(read, of: playlist, as: result) {
                guard step < playlist.edits.count else {
                    // No step lists these rows: the playlist changed elsewhere.
                    playlistEdits[playlistID] = nil
                    return result.map(\.track)
                }
                playlist.apply(playlist.edits[step], to: &entries)
                step += 1
                read = visible(entries, of: playlist)
            }
            // From this step on every step lists the rows the edits leave (the read has every
            // edit, or the rest change nothing it lists): nothing is left to lay over a read.
            var later = entries
            let settled = read == final && playlist.edits[step...].allSatisfy { edit in
                playlist.apply(edit, to: &later)
                return visible(later, of: playlist) == final
            }
            guard !settled else {
                playlistEdits[playlistID] = nil
                return result.map(\.track)
            }
            playlist.shownStep = step
            playlistEdits[playlistID] = playlist
            let rows = Dictionary(zip(read, result.map(\.track)), uniquingKeysWith: { first, _ in first })
            // A copy the read doesn't have yet. The row of a copy it lists that the edits took out
            // stands in for it, so a read that already has it looks the same as one that doesn't.
            let kept = Set(final)
            var standIns = read.indices.filter { !kept.contains(read[$0]) }
            return final.compactMap { entry in
                if let row = rows[entry] { return row }
                guard case let .added(index) = entry else { return nil }
                let addition = playlist.additions[index]
                if let standIn = standIns.firstIndex(where: { !result[$0].keys.isDisjoint(with: addition.keys) }) {
                    return result[standIns.remove(at: standIn)].track
                }
                return addition.track
            }
        }
    }

    /// True when `rows` are the playlist's `entries`, one by one.
    private static func lists(
        _ entries: [PlaylistEdits.Entry],
        of playlist: PlaylistEdits,
        as rows: [(track: MusicTrack, keys: Set<String>)]
    ) -> Bool {
        entries.count == rows.count && zip(entries, rows).allSatisfy { entry, row in
            !playlist.keys(of: entry).isDisjoint(with: row.keys)
        }
    }

    /// True when `playlistID` has edits a read of its tracks has to account for.
    func hasPendingTracks(playlistID: String) -> Bool {
        locked {
            expire()
            return playlistEdits[playlistID] != nil
        }
    }

    /// True when Liked Songs has edits a read has to account for.
    /// True when a song removed from the library may still be listed, in the library or in a
    /// playlist.
    var hasRemovedSongs: Bool {
        locked {
            expire()
            return !removedSongs.isEmpty
        }
    }

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
        playlistEdits = playlistEdits.filter { $0.value.at >= cutoff }
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
