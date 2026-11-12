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

    /// How an edit reaches the library on this Mac. Each way keeps the order of its own edits,
    /// but the two don't wait for each other: the Music app changes this Mac's library at once,
    /// while an add through the Apple Music API comes back from the cloud, which took over half an
    /// hour in testing.
    enum EditRoute {
        case api
        case musicApp
    }

    /// Every add and remove made from Spotiglass in one playlist that the library may not show
    /// yet, in order, over the playlist as it showed before the first of them (#393).
    ///
    /// Each read lists the playlist after some of the API edits and some of the Music app's, the
    /// first ones of each in the order they were made (its step). A read is matched row by row
    /// to a step it lists exactly and shown as the playlist after every edit. Whole rows, not
    /// counts per song, tell apart steps that list each song equally often in other places: a
    /// copy removed and added back moves to the end, and so do other songs' copies.
    private struct PlaylistEdits {
        /// A row of the playlist after some of the edits.
        enum Entry: Hashable {
            /// A row the playlist showed before the first edit, by its place then.
            case listed(Int)
            /// A copy added from Spotiglass, by its index in `additions`.
            case added(Int)
        }

        /// One edit from the browser: everything one add or remove did at once.
        enum Edit {
            case add([Int], EditRoute)
            /// Removals always go through the Music app.
            case remove([Entry])

            var route: EditRoute {
                if case let .add(_, route) = self { return route }
                return .musicApp
            }
        }

        /// How many of each route's edits a read has.
        struct Step: Hashable {
            var api = 0
            var musicApp = 0

            func has(_ other: Step) -> Bool { api >= other.api && musicApp >= other.musicApp }
        }

        struct Addition {
            let track: MusicTrack
            let keys: Set<String>
        }

        /// The rows' IDs as the playlist showed them before the first edit.
        let listed: [String]
        var additions: [Addition] = []
        var edits: [Edit] = []
        /// The step the latest read showed: the library never goes back past it on either route.
        var shownStep = Step()
        var at: Date
        /// When a read showed every edit. The record stays a little longer for reads that started
        /// before it and finish after it.
        var settledAt: Date?

        var lastStep: Step {
            Step(api: edits.filter { $0.route == .api }.count, musicApp: edits.filter { $0.route == .musicApp }.count)
        }

        /// Every step, the ones that have `step` first, fewest edits first.
        func steps(from step: Step) -> [Step] {
            let last = lastStep
            let all = (0...last.api).flatMap { api in (0...last.musicApp).map { Step(api: api, musicApp: $0) } }
            return all.sorted { lhs, rhs in
                let (lhsLater, rhsLater) = (lhs.has(step), rhs.has(step))
                if lhsLater != rhsLater { return lhsLater }
                return lhs.api + lhs.musicApp < rhs.api + rhs.musicApp
            }
        }

        /// The playlist's rows after `step`: the listed rows left, then the added copies left, in
        /// the order they were added (removing takes rows out, adding appends).
        func entries(after step: Step) -> [Entry] {
            var added: [Entry] = []
            var removed = Set<Entry>()
            var done = Step()
            for edit in edits {
                switch edit.route {
                case .api:
                    done.api += 1
                    if done.api > step.api { continue }
                case .musicApp:
                    done.musicApp += 1
                    if done.musicApp > step.musicApp { continue }
                }
                switch edit {
                case let .add(indices, _): added += indices.map(Entry.added)
                case let .remove(entries): removed.formUnion(entries)
                }
            }
            return (listed.indices.map(Entry.listed) + added).filter { !removed.contains($0) }
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
        route: EditRoute,
        playlistID: String,
        shown: [MusicTrack]
    ) {
        guard !songs.isEmpty else { return }
        locked {
            editPlaylist(playlistID, shown: shown) { playlist in
                let first = playlist.additions.count
                playlist.additions += songs.map { song in
                    .init(track: song.track, keys: song.reference.matchKeys.union([song.track.id, Self.metadataKey(song.track)]))
                }
                playlist.edits.append(.add(Array(first..<playlist.additions.count), route))
            }
        }
    }

    /// Records removing the rows at `positions` of `shown`, the playlist as the browser showed
    /// it before the edit (pending edits included).
    func recordPlaylistRemoval(at positions: [Int], playlistID: String, shown: [MusicTrack]) {
        guard !positions.isEmpty else { return }
        locked {
            editPlaylist(playlistID, shown: shown) { playlist in
                let entries = visible(playlist.entries(after: playlist.lastStep), of: playlist)
                playlist.edits.append(.remove(Set(positions).filter(entries.indices.contains).sorted().map { entries[$0] }))
            }
        }
    }

    /// True when one of the rows at `positions` of `shown` is a copy added through the Apple
    /// Music API that no read has listed yet: the Music app doesn't have it, so removing it
    /// there would take another copy of the song instead.
    func isOnItsWayFromTheCloud(_ positions: [Int], playlistID: String, shown: [MusicTrack]) -> Bool {
        locked {
            guard let playlist = playlistEdits[playlistID] else { return false }
            let final = visible(playlist.entries(after: playlist.lastStep), of: playlist)
            guard final.count == shown.count else { return false }
            let read = Set(playlist.entries(after: playlist.shownStep))
            let fromTheAPI = Set(playlist.edits.flatMap { edit -> [Int] in
                if case let .add(indices, .api) = edit { return indices }
                return []
            })
            return positions.contains { position in
                guard final.indices.contains(position), case let .added(index) = final[position] else { return false }
                return fromTheAPI.contains(index) && !read.contains(final[position])
            }
        }
    }

    /// Adds edits to the playlist's record. The playlist as shown is its record after every
    /// edit; a record that doesn't list as many rows (the playlist changed elsewhere since)
    /// starts over from what is shown.
    private func editPlaylist(_ id: String, shown: [MusicTrack], _ edit: (inout PlaylistEdits) -> Void) {
        var playlist = playlistEdits[id].flatMap { playlist in
            visible(playlist.entries(after: playlist.lastStep), of: playlist).count == shown.count ? playlist : nil
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
    /// `isComplete` is false when the read stopped at its limit, so rows past it prove nothing.
    func applied(
        toPlaylistTracks tracks: [(track: MusicTrack, keys: Set<String>)],
        playlistID: String,
        isComplete: Bool = true
    ) -> [MusicTrack] {
        locked {
            expire()
            let result = tracks.filter { track in
                !removedSongs.keys.contains { !$0.isDisjoint(with: track.keys) }
            }
            guard var playlist = playlistEdits[playlistID] else { return result.map(\.track) }
            if let settledAt = playlist.settledAt, now().timeIntervalSince(settledAt) > Self.settledGrace {
                playlistEdits[playlistID] = nil
                return result.map(\.track)
            }
            let final = visible(playlist.entries(after: playlist.lastStep), of: playlist)
            // The step these rows fit best, one that has the latest read's first (an older read
            // finishing late fits an earlier one). Rows no step has were added elsewhere, rows a
            // step has that the read lacks were removed elsewhere.
            let steps = playlist.steps(from: playlist.shownStep)
            let entries = { (step: PlaylistEdits.Step) in self.visible(playlist.entries(after: step), of: playlist) }
            // Usually a step lists exactly these rows; pairing rows up is only needed otherwise.
            var best: (step: PlaylistEdits.Step, fit: Fit)?
            for step in steps {
                let listed = entries(step)
                let exact = listed.count == result.count && zip(listed, result).allSatisfy { entry, row in
                    !playlist.keys(of: entry).isDisjoint(with: row.keys)
                }
                if exact {
                    best = (step, Fit(rows: Dictionary(uniqueKeysWithValues: zip(result.indices, listed))))
                    break
                }
            }
            if best == nil {
                for step in steps {
                    let fit = Self.fit(result, to: entries(step), of: playlist, isComplete: isComplete)
                    if best.map({ fit.misses < $0.fit.misses }) ?? true { best = (step, fit) }
                }
            }
            guard let (step, fit) = best else { return result.map(\.track) }
            if step.has(playlist.shownStep) {
                // Every step from this one on lists the rows the edits leave, and the read has
                // every copy added: nothing is left to lay over a read.
                let settled = playlist.steps(from: step).filter { $0.has(step) }.allSatisfy { later in
                    visible(playlist.entries(after: later), of: playlist) == final
                } && Set(final.filter { if case .added = $0 { true } else { false } }).isSubset(of: Set(fit.rows.values))
                playlist.shownStep = step
                if settled {
                    if playlist.settledAt == nil { playlist.settledAt = now() }
                    playlistEdits[playlistID] = playlist
                    return result.map(\.track)
                }
                playlist.settledAt = nil
                playlistEdits[playlistID] = playlist
            }
            // Rows in the read's order, without the ones the edits took out; then the copies the
            // read doesn't have yet. The row of a copy the edits took out stands in for one of
            // them, so a read that already has it looks the same as one that doesn't.
            let kept = Set(final)
            var shown: [MusicTrack] = []
            var standIns: [Int] = []
            var listed = Set<PlaylistEdits.Entry>()
            for (index, row) in result.enumerated() {
                guard let entry = fit.rows[index] else {
                    shown.append(row.track)
                    continue
                }
                if kept.contains(entry) {
                    shown.append(row.track)
                    listed.insert(entry)
                } else {
                    standIns.append(index)
                }
            }
            for entry in final where !listed.contains(entry) {
                guard case let .added(index) = entry else { continue }
                let addition = playlist.additions[index]
                if let standIn = standIns.firstIndex(where: { !result[$0].keys.isDisjoint(with: addition.keys) }) {
                    shown.append(result[standIns.remove(at: standIn)].track)
                } else {
                    shown.append(addition.track)
                }
            }
            return shown
        }
    }

    /// How long a record that a read showed in full stays for reads that started before it.
    static let settledGrace: TimeInterval = 60

    /// Which entry each row of a read is, and how many rows and entries didn't pair up.
    private struct Fit {
        var rows: [Int: PlaylistEdits.Entry] = [:]
        var misses = 0
    }

    /// Pairs the read's rows with `entries` in order: a row is the next entry it can be, rows
    /// before it no entry can be count as misses, and so do the entries skipped to reach it.
    /// Entries past the end of an incomplete read aren't misses.
    private static func fit(
        _ rows: [(track: MusicTrack, keys: Set<String>)],
        to entries: [PlaylistEdits.Entry],
        of playlist: PlaylistEdits,
        isComplete: Bool
    ) -> Fit {
        var places: [String: [Int]] = [:]
        for (place, entry) in entries.enumerated() {
            for key in playlist.keys(of: entry) {
                places[key, default: []].append(place)
            }
        }
        var fit = Fit()
        var next = 0
        for (index, row) in rows.enumerated() {
            let place = row.keys.compactMap { key in places[key]?.first { $0 >= next } }.min()
            guard let place else {
                fit.misses += 1
                continue
            }
            fit.misses += place - next
            fit.rows[index] = entries[place]
            next = place + 1
        }
        if isComplete { fit.misses += entries.count - next }
        return fit
    }

    /// True when `playlistID` has edits a read of its tracks has to account for.
    func hasPendingTracks(playlistID: String) -> Bool {
        locked {
            expire()
            return playlistEdits[playlistID].map { $0.settledAt == nil } ?? false
        }
    }

    /// True when reads of `playlistID` go through `applied(toPlaylistTracks:)`: it has pending
    /// edits, or a read showed them all moments ago and one that started before may still finish.
    func laysEditsOver(playlistID: String) -> Bool {
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
