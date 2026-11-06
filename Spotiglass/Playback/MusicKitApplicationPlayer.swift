import Foundation
import MusicKit

/// The live ``AppleMusicPlayerControlling``: MusicKit's `ApplicationMusicPlayer.shared`, plus
/// the lookups that turn `applemusic:` URIs back into MusicKit items.
///
/// Songs come from ``AppleMusicPlayableRegistry`` (the items the browser mapped); anything
/// else is looked up in the library first, then in the catalog. Albums and playlists are
/// queued song by song, so the player can report each song under the URI its row has and the
/// browser can mark the playing row.
@MainActor
final class MusicKitApplicationPlayer: AppleMusicPlayerControlling {
    /// Songs that are not in ``AppleMusicPlayableRegistry`` are looked up one by one; a longer
    /// list than this plays the songs found so far.
    static let fallbackLookupLimit = 50
    /// An album or playlist plays this many songs at most.
    static let contextTrackLimit = 1_000
    /// An artist "context" plays this many songs at most.
    static let artistSongLimit = 100

    private let player = ApplicationMusicPlayer.shared
    /// The row URI of each queued song. MusicKit hands queued entries back with new ids and
    /// with the song's catalog id instead of the library id the row was built with, so entries
    /// are matched on what they show: title, subtitle and length, then title and subtitle
    /// alone (``entryKeys(title:subtitle:durationSeconds:)``).
    private var uriByEntryKey: [String: String] = [:]
    /// The row at each queue position and where the added songs are (positions, because
    /// MusicKit's entry ids don't last); see ``AppleMusicQueueBook``.
    private var book = AppleMusicQueueBook()
    /// Shuffle as last asked for. MusicKit drops its shuffle mode when the queue is replaced
    /// (and before there is a queue), so every new queue gets it again.
    private lazy var shuffleWanted = player.state.shuffleMode == .songs
    /// Repeat as last asked for, set again on every new queue like shuffle.
    private var repeatWanted: MusicPlayer.RepeatMode?

    func isAuthorized() -> Bool {
        MusicAuthorization.currentStatus == .authorized
    }

    func play(_ request: AppleMusicQueueRequest, isCurrent: @escaping @MainActor () -> Bool) async throws {
        try await requireSubscription()
        let resolved: [(uri: String, entry: MusicPlayer.Queue.Entry)]
        var startURI: String?
        switch request {
        case let .items(uris, start):
            resolved = try await Self.resolveEntries(uris, lookingUpFirst: start)
            startURI = start
        case let .album(id):
            guard let album = try await Self.album(id: id) else { throw Self.notFound(id) }
            resolved = try await Self.entries(for: Self.tracks(of: album))
        case let .playlist(id):
            guard let playlist = try await Self.playlist(id: id) else { throw Self.notFound(id) }
            resolved = try await Self.entries(for: Self.tracks(of: playlist))
        case let .artist(id):
            resolved = Self.entries(for: try await Self.artistSongs(id: id))
        }
        guard isCurrent() else { throw CancellationError() }
        guard !resolved.isEmpty else { throw Self.notFound("\(request)") }
        // The row that was clicked must play; if it couldn't be found, say so instead of
        // quietly starting another song.
        if let startURI, !resolved.contains(where: { $0.uri == startURI }) { throw Self.notFound(startURI) }
        let startIndex = resolved.firstIndex { $0.uri == startURI } ?? 0
        // Songs added with Add to queue that haven't played yet stay queued, right after the
        // new first song, like Spotify's queue. With shuffle off they go into the new queue
        // as it is set; with shuffle on MusicKit reshuffles a new queue, so they are inserted
        // after that instead, or they'd end up anywhere in it.
        let carried = carriedAddedSongs()
        let carriedInQueue = shuffleWanted ? [] : carried
        var queued = resolved
        queued.insert(contentsOf: carriedInQueue, at: startIndex + 1)
        uriByEntryKey = [:]
        for item in queued + (shuffleWanted ? carried : []) {
            remember(item.uri, for: item.entry)
        }
        book.replace(
            with: queued.map { AppleMusicQueueBook.Row(uri: $0.uri, title: $0.entry.title) },
            carryingAdded: carriedInQueue.count,
            after: startIndex
        )
        player.queue = ApplicationMusicPlayer.Queue(queued.map(\.entry), startingAt: resolved[startIndex].entry)
        applyModesToNewQueue()
        try await Self.mapped { try await self.player.play() }
        // The player switches to a queue it was given only once it plays, so with shuffle on
        // the carried songs go in now. Each goes right after the current song, so inserting
        // the last first keeps the order they were added in.
        if shuffleWanted, !carried.isEmpty, isCurrent() {
            for item in carried.reversed() {
                try await Self.mapped {
                    try await self.player.queue.insert(item.entry, position: .afterCurrentEntry)
                }
            }
            let entries = player.queue.entries
            if let current = player.queue.currentEntry,
               let currentIndex = entries.firstIndex(where: { $0.id == current.id }) {
                book.markAdded(start: currentIndex + 1, count: carried.count)
            }
        }
    }

    func pause() {
        player.pause()
    }

    func resume() async throws {
        try await Self.mapped { try await self.player.play() }
    }

    func stop() {
        player.stop()
    }

    func seek(toMilliseconds milliseconds: Int) {
        player.playbackTime = TimeInterval(milliseconds) / 1000
    }

    func skipToNext() async throws {
        try await Self.mapped { try await self.player.skipToNextEntry() }
    }

    func skipToPrevious() async throws {
        try await Self.mapped { try await self.player.skipToPreviousEntry() }
    }

    func setShuffle(_ enabled: Bool) {
        // Compared with what was last asked for, not with what the player reports: its state
        // trails commands, so a quick on-then-off would otherwise be dropped.
        let changed = enabled != shuffleWanted
        shuffleWanted = enabled
        // Positions hold until shuffle reorders the queue: note each entry's row by id first.
        if changed { noteEntries() }
        player.state.shuffleMode = enabled ? .songs : .off
        if changed { book.forgetPositions() }
    }

    /// Sets the shuffle and repeat last asked for on a queue just set, without trusting what
    /// the player reports right then (its state trails commands by up to a third of a second).
    private func applyModesToNewQueue() {
        if shuffleWanted {
            noteEntries()
            player.state.shuffleMode = .songs
            book.forgetPositions()
        } else {
            player.state.shuffleMode = .off
        }
        if let repeatWanted {
            player.state.repeatMode = repeatWanted
        }
    }

    /// The added songs still ahead in the current queue, as new entries for the next queue.
    private func carriedAddedSongs() -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        let entries = Array(player.queue.entries)
        let currentIndex = player.queue.currentEntry.flatMap { current in
            entries.firstIndex { $0.id == current.id }
        }
        guard let range = book.addedAhead(of: currentIndex) else { return [] }
        return range.compactMap { index -> (uri: String, entry: MusicPlayer.Queue.Entry)? in
            guard entries.indices.contains(index), case let .song(song) = entries[index].item else { return nil }
            let entry = entries[index]
            let uri = book.rowURI(entryID: entry.id, at: index, title: entry.title)
                ?? Self.keys(entry).lazy.compactMap({ self.uriByEntryKey[$0] }).first
                ?? AppleMusicItemMapping.track(song).uri
            return (uri, MusicPlayer.Queue.Entry(song))
        }
    }

    func setRepeat(_ mode: MusicRepeatMode) {
        let wanted: MusicPlayer.RepeatMode
        switch mode {
        case .off: wanted = MusicPlayer.RepeatMode.none
        case .context: wanted = .all
        case .track: wanted = .one
        }
        repeatWanted = wanted
        player.state.repeatMode = wanted
    }

    func enqueue(uri: String) async throws {
        guard let resolved = try await Self.resolveEntries([uri]).first else { throw Self.notFound(uri) }
        remember(uri, for: resolved.entry)
        // After a shuffle the ids give the positions back; the add is then placed and
        // recorded by position.
        noteEntries()
        let entries = player.queue.entries
        let currentIndex = player.queue.currentEntry.flatMap { current in
            entries.firstIndex { $0.id == current.id }
        }
        let plan = book.planAdd(
            AppleMusicQueueBook.Row(uri: uri, title: resolved.entry.title),
            currentIndex: currentIndex,
            entryCount: entries.count
        )
        if let index = plan.index, !plan.isAfterCurrent {
            player.queue.entries.insert(resolved.entry, at: index)
        } else {
            try await Self.mapped {
                try await self.player.queue.insert(resolved.entry, position: .afterCurrentEntry)
            }
        }
        book.finishAdd(plan)
    }

    func readState() -> AppleMusicPlayerState {
        let current = player.queue.currentEntry
        let currentIndex = current.flatMap { current in player.queue.entries.firstIndex { $0.id == current.id } }
        let status: AppleMusicPlayerState.Status
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: status = .playing
        case .paused: status = .paused
        case .stopped, .interrupted: status = .stopped
        @unknown default: status = .stopped
        }
        let seconds = player.playbackTime
        return AppleMusicPlayerState(
            status: status,
            current: current.flatMap { track(for: $0, at: currentIndex) },
            positionMilliseconds: seconds.isFinite ? max(0, Int((seconds * 1000).rounded())) : 0,
            shuffle: player.state.shuffleMode == .songs,
            repeatMode: Self.repeatMode(player.state.repeatMode)
        )
    }

    func readUpcoming() -> [MusicTrack] {
        noteEntries()
        let entries = Array(player.queue.entries)
        guard let currentID = player.queue.currentEntry?.id,
              let currentIndex = entries.firstIndex(where: { $0.id == currentID })
        else { return [] }
        return entries.indices.dropFirst(currentIndex + 1).compactMap { track(for: entries[$0], at: $0) }
    }

    // MARK: - Mapping

    private func noteEntries() {
        let entries = Array(player.queue.entries)
        book.noteEntries(ids: entries.map(\.id), titles: entries.map(\.title))
    }

    private func track(for entry: MusicPlayer.Queue.Entry, at index: Int?) -> MusicTrack? {
        let mapped: MusicTrack
        switch entry.item {
        case let .song(song):
            mapped = AppleMusicItemMapping.track(song)
        case let .musicVideo(video):
            mapped = AppleMusicItemMapping.track(.musicVideo(video))
        case nil:
            return nil
        @unknown default:
            return nil
        }
        let rowURI = book.rowURI(entryID: entry.id, at: index, title: entry.title)
            ?? Self.keys(entry).lazy.compactMap({ self.uriByEntryKey[$0] }).first
        guard let uri = rowURI, uri != mapped.uri else { return mapped }
        return MusicTrack(
            id: mapped.id,
            name: mapped.name,
            artists: mapped.artists,
            artistRefs: mapped.artistRefs,
            albumArtworkURL: mapped.albumArtworkURL,
            albumName: mapped.albumName,
            albumID: mapped.albumID,
            durationMilliseconds: mapped.durationMilliseconds,
            isExplicit: mapped.isExplicit,
            isPlayable: mapped.isPlayable,
            linkedFromID: mapped.linkedFromID,
            uri: uri
        )
    }

    private static func repeatMode(_ mode: MusicPlayer.RepeatMode?) -> MusicRepeatMode {
        switch mode {
        case .all: .context
        case .one: .track
        case .none, nil: .off
        @unknown default: .off
        }
    }

    /// The first row URI queued under each of the entry's keys wins.
    private func remember(_ uri: String, for entry: MusicPlayer.Queue.Entry) {
        for key in Self.keys(entry) where uriByEntryKey[key] == nil {
            uriByEntryKey[key] = uri
        }
    }

    private static func keys(_ entry: MusicPlayer.Queue.Entry) -> [String] {
        let duration: TimeInterval?
        switch entry.item {
        case let .song(song): duration = song.duration
        case let .musicVideo(video): duration = video.duration
        case nil: duration = nil
        @unknown default: duration = nil
        }
        return entryKeys(
            title: entry.title,
            subtitle: entry.subtitle,
            durationSeconds: duration.map { Int($0.rounded()) }
        )
    }

    /// The keys a queued entry is matched by, most precise first. Two recordings with the same
    /// title and artist (a standard and a deluxe edition) usually differ in length, so the
    /// first key tells them apart; the second still matches when the library and the catalog
    /// report slightly different lengths for one recording.
    static func entryKeys(title: String, subtitle: String?, durationSeconds: Int?) -> [String] {
        let base = "\(title)\u{1}\(subtitle ?? "")"
        guard let durationSeconds else { return [base] }
        return ["\(base)\u{1}\(durationSeconds)", base]
    }

    /// Songs of an album or playlist, under the URIs the browser gives their rows.
    private static func entries(for tracks: [Track]) -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        entries(for: tracks.compactMap { track -> Song? in
            if case let .song(song) = track { return song }
            return nil
        })
    }

    private static func entries(for songs: [Song]) -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        songs.map { (AppleMusicItemMapping.track($0).uri, MusicPlayer.Queue.Entry($0)) }
    }

    private static func tracks(of album: Album) async throws -> [Track] {
        let detailed = try await mapped { try await album.with([.tracks]) }
        return try await collect(detailed.tracks)
    }

    private static func tracks(of playlist: Playlist) async throws -> [Track] {
        let detailed = try await mapped { try await playlist.with([.tracks]) }
        return try await collect(detailed.tracks)
    }

    /// Follows MusicKit batches up to ``contextTrackLimit`` items.
    private static func collect(_ collection: MusicItemCollection<Track>?) async throws -> [Track] {
        guard var batch = collection else { return [] }
        var items = Array(batch)
        while items.count < contextTrackLimit, batch.hasNextBatch {
            guard let next = try await mapped({ try await batch.nextBatch() }) else { break }
            items.append(contentsOf: next)
            batch = next
        }
        return Array(items.prefix(contextTrackLimit))
    }

    // MARK: - Lookups

    /// Songs for `uris`, in the given order: the item the row was built from when the
    /// registry still has it, otherwise a lookup. URIs that resolve to nothing are left out,
    /// and so are music videos: MusicKit's player can't queue them on macOS. `firstURI` (the
    /// row that was clicked) is looked up before the others, so it is never past the limit.
    static func resolveEntries(
        _ uris: [String],
        lookingUpFirst firstURI: String? = nil,
        registry: AppleMusicPlayableRegistry = .shared
    ) async throws -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        var byID: [String: Song] = [:]
        var lookupIDs: [String] = []
        for uri in uris {
            guard let (kind, id) = AppleMusicPlaybackProvider.reference(uri), kind != "music-video" else { continue }
            if let song = registry.song(for: uri) {
                byID[id] = song
            } else if uri == firstURI {
                lookupIDs.insert(id, at: 0)
            } else {
                lookupIDs.append(id)
            }
        }
        for id in lookupIDs.prefix(fallbackLookupLimit) where byID[id] == nil {
            byID[id] = try await song(id: id)
        }
        return uris.compactMap { uri in
            guard let (_, id) = AppleMusicPlaybackProvider.reference(uri), let song = byID[id] else { return nil }
            return (uri, MusicPlayer.Queue.Entry(song))
        }
    }

    /// One song by id: library first, then the catalog. One request per id, because a library
    /// request answers with songs whose ids differ from the ones asked for, so a batch's
    /// answers can't be matched back to its ids.
    private static func song(id: String) async throws -> Song? {
        let itemID = MusicItemID(id)
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: itemID)
        if let song = try await mapped({ try await request.response().items.first }) { return song }
        return try await mapped {
            try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: itemID).response().items.first
        }
    }

    private static func album(id: String) async throws -> Album? {
        let itemID = MusicItemID(id)
        var request = MusicLibraryRequest<Album>()
        request.filter(matching: \.id, equalTo: itemID)
        if let album = try await mapped({ try await request.response().items.first }) { return album }
        return try await mapped {
            try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID).response().items.first
        }
    }

    private static func playlist(id: String) async throws -> Playlist? {
        let itemID = MusicItemID(id)
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: itemID)
        if let playlist = try await mapped({ try await request.response().items.first }) { return playlist }
        return try await mapped {
            try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: itemID).response().items.first
        }
    }

    /// A library artist plays their songs in the library; a catalog artist its top songs.
    private static func artistSongs(id: String) async throws -> [Song] {
        let itemID = MusicItemID(id)
        var artistRequest = MusicLibraryRequest<Artist>()
        artistRequest.filter(matching: \.id, equalTo: itemID)
        if let artist = try await mapped({ try await artistRequest.response().items.first }) {
            var songRequest = MusicLibraryRequest<Song>()
            songRequest.filter(matching: \.artists, contains: artist)
            songRequest.limit = artistSongLimit
            let songs: MusicLibraryResponse<Song> = try await mapped { try await songRequest.response() }
            return Array(songs.items)
        }
        let artist = try await mapped {
            try await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: itemID).response().items.first
        }
        guard let detailed = try await mapped({ try await artist?.with([.topSongs]) }) else { return [] }
        return Array((detailed.topSongs ?? []).prefix(artistSongLimit))
    }

    // MARK: - Errors

    private func requireSubscription() async throws {
        let subscription = try await Self.mapped { try await MusicSubscription.current }
        guard subscription.canPlayCatalogContent else {
            throw MusicPlaybackError(service: .appleMusic, reason: .subscriptionRequired(message: nil), detail: "canPlayCatalogContent is false")
        }
    }

    private static func notFound(_ id: String) -> MusicPlaybackError {
        MusicPlaybackError(service: .appleMusic, reason: .notFound, detail: "No Apple Music item for \(id)")
    }

    /// Runs a MusicKit call and turns its failure into a ``MusicPlaybackError``.
    private static func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as MusicPlaybackError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MusicTokenRequestError {
            switch error {
            case .permissionDenied, .userTokenRevoked, .userNotSignedIn:
                throw MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: String(describing: error))
            default:
                throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
            }
        } catch let error as URLError {
            throw MusicPlaybackError(service: .appleMusic, reason: .network(error.localizedDescription), detail: String(describing: error))
        } catch {
            throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
        }
    }
}
