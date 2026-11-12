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
    /// first ones of each in the order they were made (its step). A read is matched to the step it
    /// fits best and shown as the playlist after every edit, in the order the edits were made.
    /// Rows no step explains (added or moved elsewhere) stay after the row they follow in the read.
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

        /// A row of a view this record made.
        enum ViewRow {
            /// The read's row at this index.
            case read(Int)
            /// A copy added from Spotiglass that the read doesn't list yet, by its index in
            /// `additions`.
            case pending(Int)
        }

        /// A view this record made, so an edit can tell which row the browser showed where.
        struct View {
            let ids: [String]
            let rows: [ViewRow]
            /// The read it was made from: each row's keys and the entry it was paired with (`nil`
            /// for a row no step explains).
            let read: [(keys: Set<String>, entry: Entry?)]
        }

        /// Each row's keys (its ID, title and artist) as the playlist showed them before the
        /// first edit.
        let listed: [Set<String>]
        var additions: [Addition] = []
        var edits: [Edit] = []
        /// The step the latest read showed: the library never goes back past it on either route.
        var shownStep = Step()
        var at: Date
        /// When a read showed every edit. The record stays a little longer for reads that started
        /// before it and finish after it.
        var settledAt: Date?
        /// The latest views, newest last.
        var views: [View] = []

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

        /// The edits a read at `step` has, in order.
        func edits(in step: Step) -> [Edit] {
            var done = Step()
            return edits.filter { edit in
                switch edit.route {
                case .api:
                    done.api += 1
                    return done.api <= step.api
                case .musicApp:
                    done.musicApp += 1
                    return done.musicApp <= step.musicApp
                }
            }
        }

        /// The playlist's rows after `step`: the listed rows left, then the added copies left, in
        /// the order they were added (removing takes rows out, adding appends).
        func entries(after step: Step) -> [Entry] {
            var added: [Entry] = []
            var removed = Set<Entry>()
            for edit in edits(in: step) {
                switch edit {
                case let .add(indices, _): added += indices.map(Entry.added)
                case let .remove(entries): removed.formUnion(entries)
                }
            }
            return (listed.indices.map(Entry.listed) + added).filter { !removed.contains($0) }
        }

        func keys(of entry: Entry) -> Set<String> {
            switch entry {
            case let .listed(index): listed[index]
            case let .added(index): additions[index].keys
            }
        }

        /// The record over the read `view` was made from: its rows are the listed ones, rows of it
        /// the edits took out are taken out again, and copies it doesn't have yet stay pending.
        /// Also returns the entry of each row of the view.
        func rebased(on view: View, at now: Date) -> (PlaylistEdits, [Entry]?) {
            var record = PlaylistEdits(listed: view.read.map(\.keys), at: now)
            let final = Set(entries(after: lastStep))
            let read = Set(view.read.compactMap(\.entry))
            let removed = view.read.indices.filter { index in view.read[index].entry.map { !final.contains($0) } ?? false }
            if !removed.isEmpty { record.edits.append(.remove(removed.map(Entry.listed))) }
            var moved: [Int: Int] = [:]
            for case let .add(indices, route) in edits {
                let pending = indices.filter { final.contains(.added($0)) && !read.contains(.added($0)) }
                guard !pending.isEmpty else { continue }
                let first = record.additions.count
                for index in pending {
                    moved[index] = record.additions.count
                    record.additions.append(additions[index])
                }
                record.edits.append(.add(Array(first..<record.additions.count), route))
            }
            let rows = view.rows.map { row -> Entry? in
                switch row {
                case let .read(index): .listed(index)
                case let .pending(index): moved[index].map(Entry.added)
                }
            }
            return (record, rows.allSatisfy { $0 != nil } ? rows.compactMap { $0 } : nil)
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
            editPlaylist(playlistID, shown: shown) { playlist, _ in
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
            editPlaylist(playlistID, shown: shown) { playlist, rows in
                // A view the record didn't make can't say which rows these are; the library
                // shows the removal when it catches up.
                guard let rows else { return }
                let picked = Set(positions).filter(rows.indices.contains).sorted().map { rows[$0] }
                if !picked.isEmpty { playlist.edits.append(.remove(picked)) }
            }
        }
    }

    /// True when one of the rows at `positions` of `shown` is a copy added through the Apple
    /// Music API that no read has listed yet: the Music app doesn't have it, so removing it
    /// there would take another copy of the song instead.
    func isOnItsWayFromTheCloud(_ positions: [Int], playlistID: String, shown: [MusicTrack]) -> Bool {
        locked {
            let ids = shown.map(\.id)
            guard let playlist = playlistEdits[playlistID], let view = playlist.views.last(where: { $0.ids == ids }) else {
                return false
            }
            var fromTheAPI = Set<Int>()
            for case let .add(indices, .api) in playlist.edits {
                fromTheAPI.formUnion(indices)
            }
            return positions.contains { position in
                guard view.rows.indices.contains(position), case let .pending(index) = view.rows[position] else { return false }
                return fromTheAPI.contains(index)
            }
        }
    }

    /// Adds edits to the playlist's record, with the entry of each row of `shown` when the
    /// record made that view. Rows of it no step explains move the record onto the read the view
    /// was made from first.
    private func editPlaylist(
        _ id: String,
        shown: [MusicTrack],
        _ edit: (inout PlaylistEdits, [PlaylistEdits.Entry]?) -> Void
    ) {
        let ids = shown.map(\.id)
        var playlist: PlaylistEdits
        var rows: [PlaylistEdits.Entry]?
        if let existing = playlistEdits[id] {
            playlist = existing
            if let view = existing.views.last(where: { $0.ids == ids }) {
                let entries = view.rows.map { row -> PlaylistEdits.Entry? in
                    switch row {
                    case let .read(index): view.read[index].entry
                    case let .pending(index): .added(index)
                    }
                }
                if entries.allSatisfy({ $0 != nil }) {
                    rows = entries.compactMap { $0 }
                } else {
                    (playlist, rows) = existing.rebased(on: view, at: now())
                }
            } else {
                // Edits made one after another with no read between show the record's own rows.
                let final = existing.entries(after: existing.lastStep).filter { entry in
                    let keys = existing.keys(of: entry)
                    return !removedSongs.keys.contains { !$0.isDisjoint(with: keys) }
                }
                if final.count == shown.count { rows = final }
            }
        } else {
            playlist = PlaylistEdits(listed: shown.map { [$0.id, Self.metadataKey($0)] }, at: now())
            rows = shown.indices.map(PlaylistEdits.Entry.listed)
        }
        playlist.at = now()
        playlist.settledAt = nil
        edit(&playlist, rows)
        playlistEdits[id] = playlist
        if playlistEdits.count > Self.maxEntries, let oldest = playlistEdits.min(by: { $0.value.at < $1.value.at }) {
            playlistEdits[oldest.key] = nil
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
            let fit = fitting(result, to: playlist, isComplete: isComplete)
            let final = fit.entries(playlist.lastStep)
            let paired = fit.pairs(fit.step)
            let read = Set(paired.compactMap { $0 })
            let rawView = PlaylistEdits.View(
                ids: result.map(\.track.id),
                rows: result.indices.map(PlaylistEdits.ViewRow.read),
                read: result.indices.map { (result[$0].keys, paired[$0]) }
            )
            if fit.step.has(playlist.shownStep) {
                playlist.shownStep = fit.step
                // The read has every copy added, and every step from this one on lists the rows
                // the edits leave: nothing is left to lay over a read.
                let settled = final.allSatisfy { entry in
                    if case .added = entry { return read.contains(entry) }
                    return true
                } && playlist.steps(from: fit.step).filter { $0.has(fit.step) }.allSatisfy { fit.entries($0) == final }
                if settled {
                    if playlist.settledAt == nil { playlist.settledAt = now() }
                    playlist.views = Array((playlist.views + [rawView]).suffix(Self.keptViews))
                    playlistEdits[playlistID] = playlist
                    return result.map(\.track)
                }
                playlist.settledAt = nil
            }
            // The rows the edits leave in the order they were made, rows no step explains after
            // the row they follow in the read, then the copies the read doesn't have yet. The row
            // of a copy the edits took out stands in for one of the same song, so a read that
            // already has it looks the same as one that doesn't.
            let kept = Set(final)
            var rowOf: [PlaylistEdits.Entry: Int] = [:]
            var leading: [Int] = []
            var following: [PlaylistEdits.Entry: [Int]] = [:]
            var standIns: [Int] = []
            var anchor: PlaylistEdits.Entry?
            for index in result.indices {
                if let entry = paired[index] {
                    if kept.contains(entry) {
                        rowOf[entry] = index
                        anchor = entry
                    } else {
                        standIns.append(index)
                    }
                } else if let anchor {
                    following[anchor, default: []].append(index)
                } else {
                    leading.append(index)
                }
            }
            var rows = leading.map(PlaylistEdits.ViewRow.read)
            var shown = leading.map { result[$0].track }
            for entry in final {
                if let index = rowOf[entry] {
                    rows.append(.read(index))
                    shown.append(result[index].track)
                } else if case let .added(index) = entry {
                    let group = fit.group(of: entry)
                    rows.append(.pending(index))
                    if let standIn = standIns.firstIndex(where: { fit.group(ofRow: $0) == group }) {
                        shown.append(result[standIns.remove(at: standIn)].track)
                    } else {
                        shown.append(playlist.additions[index].track)
                    }
                }
                for index in following[entry] ?? [] {
                    rows.append(.read(index))
                    shown.append(result[index].track)
                }
            }
            playlist.views = Array((playlist.views + [.init(ids: shown.map(\.id), rows: rows, read: rawView.read)]).suffix(Self.keptViews))
            playlistEdits[playlistID] = playlist
            return shown
        }
    }

    /// How long a record that a read showed in full stays for reads that started before it.
    static let settledGrace: TimeInterval = 60
    /// Views kept per record, for edits made from one the browser shows.
    private static let keptViews = 4

    /// A read against a record: which song each row and entry is, and the step it fits best.
    private struct Fit {
        let playlist: PlaylistEdits
        let visible: (PlaylistEdits.Entry) -> Bool
        /// Rows and entries of one song share a group.
        let entryGroups: [PlaylistEdits.Entry: Int]
        let rowGroups: [Int]
        var step = PlaylistEdits.Step()

        func group(of entry: PlaylistEdits.Entry) -> Int { entryGroups[entry] ?? -1 }
        func group(ofRow index: Int) -> Int { rowGroups[index] }

        func entries(_ step: PlaylistEdits.Step) -> [PlaylistEdits.Entry] {
            playlist.entries(after: step).filter(visible)
        }

        /// The entry each row is at `step`: the next one of its song, in order.
        func pairs(_ step: PlaylistEdits.Step) -> [PlaylistEdits.Entry?] {
            var queues: [Int: ArraySlice<PlaylistEdits.Entry>] = [:]
            for entry in entries(step) {
                queues[group(of: entry), default: []].append(entry)
            }
            return rowGroups.map { group in queues[group]?.popFirst() }
        }
    }

    /// The step a read fits best. Each step is counted per song first (cheap); among the ones
    /// that list every song as often as the read, the first whose rows are in the read's order
    /// wins, else the first that leaves the fewest rows and entries unpaired.
    private func fitting(_ rows: [(track: MusicTrack, keys: Set<String>)], to playlist: PlaylistEdits, isComplete: Bool) -> Fit {
        // Songs: every key of a row or entry joins its group.
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        func join(_ keys: Set<String>) {
            guard let first = keys.first else { return }
            let target = root(first)
            parent[target] = target
            for key in keys.dropFirst() {
                let other = root(key)
                if other != target { parent[other] = target }
            }
        }
        let allEntries = playlist.listed.indices.map(PlaylistEdits.Entry.listed) + playlist.additions.indices.map(PlaylistEdits.Entry.added)
        allEntries.forEach { join(playlist.keys(of: $0)) }
        rows.forEach { join($0.keys) }
        var groupNumbers: [String: Int] = [:]
        func number(_ keys: Set<String>) -> Int {
            guard let first = keys.first else { return -1 }
            let key = root(first)
            if let number = groupNumbers[key] { return number }
            groupNumbers[key] = groupNumbers.count
            return groupNumbers.count - 1
        }
        let hidden = Set(allEntries.filter { entry in
            let keys = playlist.keys(of: entry)
            return removedSongs.keys.contains { !$0.isDisjoint(with: keys) }
        })
        var fit = Fit(
            playlist: playlist,
            visible: { !hidden.contains($0) },
            entryGroups: Dictionary(uniqueKeysWithValues: allEntries.map { ($0, number(playlist.keys(of: $0))) }),
            rowGroups: rows.map { number($0.keys) }
        )
        // How often the read and the listed rows have each song.
        var inRead: [Int: Int] = [:]
        fit.rowGroups.forEach { inRead[$0, default: 0] += 1 }
        var inListed: [Int: Int] = [:]
        for index in playlist.listed.indices where !hidden.contains(.listed(index)) {
            inListed[fit.group(of: .listed(index)), default: 0] += 1
        }
        let listedPaired = inListed.reduce(0) { $0 + min($1.value, inRead[$1.key] ?? 0) }
        let listedCount = inListed.values.reduce(0, +)
        func misses(_ step: PlaylistEdits.Step) -> Int {
            var change: [Int: Int] = [:]
            var count = listedCount
            var added = Set<Int>()
            for edit in playlist.edits(in: step) {
                switch edit {
                case let .add(indices, _):
                    for index in indices where !hidden.contains(.added(index)) {
                        added.insert(index)
                        change[fit.group(of: .added(index)), default: 0] += 1
                        count += 1
                    }
                case let .remove(entries):
                    for entry in entries where !hidden.contains(entry) {
                        if case let .added(index) = entry, !added.contains(index) { continue }
                        change[fit.group(of: entry), default: 0] -= 1
                        count -= 1
                    }
                }
            }
            let paired = listedPaired + change.reduce(0) { sum, item in
                let (group, change) = item
                let read = inRead[group] ?? 0, listed = inListed[group] ?? 0
                return sum + min(read, listed + change) - min(read, listed)
            }
            return (rows.count - paired) + (isComplete ? count - paired : 0)
        }
        let steps = playlist.steps(from: playlist.shownStep).map { (step: $0, misses: misses($0)) }
        let inOrder = steps.first { candidate in
            guard candidate.misses == 0 else { return false }
            return zip(fit.entries(candidate.step), fit.rowGroups).allSatisfy { fit.group(of: $0) == $1 }
        }
        fit.step = (inOrder ?? steps.min { $0.misses < $1.misses })?.step ?? playlist.shownStep
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
    /// ID, or a new cloud library ID). Used to end a pending edit and to tell which rows of a
    /// playlist read are the same song, never to change the library.
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
