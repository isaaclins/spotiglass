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

    /// Every edit made from Spotiglass to one song's copies in one playlist, in order.
    ///
    /// Additions and removals of the same song are one record (#393): a read that still has the
    /// old copies and a read that has the new ones can list the song equally often, and only the
    /// order of the edits tells which copies the playlist keeps. The library on this Mac catches
    /// up in the order the edits were made, so each read shows the playlist as it was after some
    /// number of them (its step); the record ends once a read can only be the last step.
    private struct PlaylistSongEdits {
        enum Edit {
            /// One of the copies the read listed before the first edit (0 = the first of them).
            case removeListed(Int)
            case add(Int)
            /// A copy added from Spotiglass, by its index in `additions`.
            case removeAdded(Int)
        }

        struct Addition {
            let track: MusicTrack
            /// Across the playlist, so added songs show in the order they were added.
            let sequence: Int
        }

        /// The playlist after some of the edits: the copies the read listed before them that
        /// are left, then the added copies that are left, as the playlist orders them.
        struct State {
            var listed: [Int]
            var added: [Int]
            var count: Int { listed.count + added.count }
        }

        var keys: Set<String>
        /// Title and artist, so adding the song back from elsewhere (under another ID) joins it.
        var metadataKeys: Set<String>
        /// How often the read listed the song before the first edit.
        let listedBefore: Int
        var edits: [Edit] = []
        var additions: [Addition] = []
        /// The earliest step a read may still show: the library never goes back past a step a
        /// read showed.
        var shownStep = 0
        var at: Date

        func state(after steps: Int) -> State {
            var state = State(listed: Array(0..<max(0, listedBefore)), added: [])
            for edit in edits.prefix(steps) {
                switch edit {
                case let .removeListed(ordinal): state.listed.removeAll { $0 == ordinal }
                case let .add(index): state.added.append(index)
                case let .removeAdded(index): state.added.removeAll { $0 == index }
                }
            }
            return state
        }

        /// Records removing these copies, each by its place among the copies the playlist shows
        /// now; copies past the given ones come off the end.
        mutating func remove(_ count: Int, ordinals: [Int]) {
            let shown = state(after: edits.count)
            let copies = shown.listed.map(Edit.removeListed) + shown.added.map(Edit.removeAdded)
            var picked = Array(Set(ordinals.filter { $0 >= 0 && $0 < copies.count })).sorted().prefix(count).map { copies[$0] }
            var remaining = shown
            for edit in picked {
                switch edit {
                case let .removeListed(ordinal): remaining.listed.removeAll { $0 == ordinal }
                case let .removeAdded(index): remaining.added.removeAll { $0 == index }
                case .add: break
                }
            }
            while picked.count < count, let last = remaining.added.popLast() {
                picked.append(.removeAdded(last))
            }
            while picked.count < count, let last = remaining.listed.popLast() {
                picked.append(.removeListed(last))
            }
            edits += picked
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
    private var playlistSongEdits: [String: [PlaylistSongEdits]] = [:]
    private var nextAdditionSequence = 0

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
    /// playlist additions of it end too.
    func recordRemovedSong(_ keys: Set<String>) {
        locked {
            savedSongs.removeAll { !$0.keys.isDisjoint(with: keys) }
            playlistSongEdits = playlistSongEdits.compactMapValues { songs in
                let kept = songs.filter { $0.keys.isDisjoint(with: keys) }
                return kept.isEmpty ? nil : kept
            }
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
            playlistSongEdits[id] = nil
            deletedPlaylists[id] = now()
            trim(&deletedPlaylists)
        }
    }

    /// `shownBefore` is how often the playlist showed the song before this addition (used when
    /// the song has no pending edits in it yet).
    func recordPlaylistAddition(
        _ track: MusicTrack,
        reference: AppleMusicSongReference,
        playlistID: String,
        shownBefore: Int = 0
    ) {
        locked {
            let keys = reference.matchKeys.union([track.id, Self.metadataKey(track)])
            editSong(keys: keys, metadataKey: Self.metadataKey(track), shownBefore: shownBefore, playlistID: playlistID) { song in
                song.additions.append(.init(track: track, sequence: nextAdditionSequence))
                song.edits.append(.add(song.additions.count - 1))
                nextAdditionSequence += 1
            }
        }
    }

    /// `shownBefore` is how often the playlist showed the song before the edit (pending
    /// additions included), `removed` how many of those the edit took out, `ordinals` which
    /// (0 = the first copy shown).
    func recordPlaylistRemoval(
        _ keys: Set<String>,
        metadataKey: String? = nil,
        removed: Int,
        shownBefore: Int,
        ordinals: [Int] = [],
        playlistID: String
    ) {
        guard removed > 0 else { return }
        locked {
            editSong(keys: keys, metadataKey: metadataKey, shownBefore: shownBefore, playlistID: playlistID) { song in
                song.remove(removed, ordinals: ordinals)
            }
        }
    }

    /// Adds an edit to the song's record in the playlist, starting one when it has none.
    private func editSong(
        keys: Set<String>,
        metadataKey: String?,
        shownBefore: Int,
        playlistID: String,
        _ edit: (inout PlaylistSongEdits) -> Void
    ) {
        var songs = playlistSongEdits[playlistID] ?? []
        let index = songs.firstIndex { song in
            !song.keys.isDisjoint(with: keys) || metadataKey.map(song.metadataKeys.contains) == true
        }
        var song = index.map { songs.remove(at: $0) } ?? PlaylistSongEdits(
            keys: [],
            metadataKeys: [],
            listedBefore: max(0, shownBefore),
            at: now()
        )
        song.keys.formUnion(keys)
        if let metadataKey { song.metadataKeys.insert(metadataKey) }
        song.at = now()
        edit(&song)
        songs.append(song)
        playlistSongEdits[playlistID] = Array(songs.suffix(Self.maxEntries))
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
            guard let songs = playlistSongEdits[playlistID] else { return result.map(\.track) }
            let rows = result.map(\.track)
            var hidden = Set<Int>()
            var added: [(sequence: Int, track: MusicTrack)] = []
            var pending: [PlaylistSongEdits] = []
            for var song in songs {
                let occurrences = result.indices.filter { !result[$0].keys.isDisjoint(with: song.keys) }
                guard let shown = Self.lay(&song, over: occurrences, rows: rows) else { continue }
                pending.append(song)
                hidden.formUnion(shown.hidden)
                if !removedSongs.keys.contains(where: { !$0.isDisjoint(with: song.keys) }) {
                    added += shown.added
                }
            }
            playlistSongEdits[playlistID] = pending.isEmpty ? nil : pending
            let kept = result.indices.filter { !hidden.contains($0) }.map { result[$0].track }
            return kept + added.sorted { $0.sequence < $1.sequence }.map(\.track)
        }
    }

    /// What a read listing the song at `occurrences` needs to show every edit: which of those
    /// rows to hide and which copies to add at the end. `nil` when the read shows them all, or
    /// lists the song in a way no step explains (the playlist changed elsewhere).
    private static func lay(
        _ song: inout PlaylistSongEdits,
        over occurrences: [Int],
        rows: [MusicTrack]
    ) -> (hidden: [Int], added: [(sequence: Int, track: MusicTrack)])? {
        let last = song.edits.count
        let steps = Array(song.shownStep...last)
        let counts = steps.map { song.state(after: $0).count }
        let final = song.state(after: last)
        // The earliest step that lists the song this often. A read can't tell a later step with
        // the same count from it, and laying the edits over the earliest one shows the same rows.
        guard let stepIndex = counts.firstIndex(of: occurrences.count) else {
            guard let low = counts.min(), let high = counts.max(), (low...high).contains(occurrences.count) else { return nil }
            // Between steps (an edit of several copies the library shows half of): the count
            // the edits leave, hiding or adding the last copies.
            let extra = occurrences.count - final.count
            let missing = final.added.suffix(max(0, -extra)).map { song.additions[$0] }
            return (Array(occurrences.suffix(max(0, extra))), missing.map { ($0.sequence, $0.track) })
        }
        let step = steps[stepIndex]
        if step == last { return nil }
        song.shownStep = step
        let read = song.state(after: step)
        var hidden: [Int] = []
        for (position, row) in occurrences.enumerated() {
            let kept = position < read.listed.count
                ? final.listed.contains(read.listed[position])
                : final.added.contains(read.added[position - read.listed.count])
            if !kept { hidden.append(row) }
        }
        // A copy the read doesn't have yet. The song's own row stands in for it where the read
        // hides one, so a read that already has it looks the same as one that doesn't.
        let missing = final.added.filter { !read.added.contains($0) }.map { song.additions[$0] }
        let added = missing.enumerated().map { offset, addition in
            (addition.sequence, offset < hidden.count ? rows[hidden[offset]] : addition.track)
        }
        return (hidden, added)
    }

    /// True when `playlistID` has edits a read of its tracks has to account for.
    func hasPendingTracks(playlistID: String) -> Bool {
        locked {
            expire()
            return playlistSongEdits[playlistID] != nil
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
        playlistSongEdits = playlistSongEdits.compactMapValues { songs in
            let kept = songs.filter { $0.at >= cutoff }
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
