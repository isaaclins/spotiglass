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
    /// Starts queues and gives back what last played when MusicKit refuses one (#476).
    private lazy var starts = AppleMusicQueueStarts<RestorePoint>(player: MusicKitQueueStarter(player: player))

    /// What the player keeps about a queue, given back with it after a refused start.
    private struct RestorePoint {
        let book: AppleMusicQueueBook
        let uris: [String: String]
    }

    /// The row URI of each queued song. MusicKit hands queued entries back with new ids and
    /// with the song's catalog id instead of the library id the row was built with, so entries
    /// are matched on what they show: title, subtitle and length, then title and subtitle
    /// alone (``entryKeys(title:subtitle:durationSeconds:)``).
    private var uriByEntryKey: [String: String] = [:]
    /// Counts the queues ``uriByEntryKey`` was filled for, so a failed add only takes back keys
    /// from the queue it was added to.
    private var uriMapGeneration = 0
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
            // The browser's reads, which follow long catalog albums and playlists without
            // MusicKit's batches (#465).
            let source = MusicKitContentSource()
            guard let album = try await Self.mapped({ try await source.album(id: id) }) else { throw Self.notFound(id) }
            resolved = try await Self.entries(for: Self.mapped { try await source.tracks(of: album, limit: Self.contextTrackLimit) })
        case let .playlist(id):
            let source = MusicKitContentSource()
            guard let tracks = try await Self.mapped({
                try await source.playlistTracks(playlistID: id, limit: Self.contextTrackLimit)
            }) else { throw Self.notFound(id) }
            resolved = Self.entries(for: tracks)
        case let .artist(id):
            resolved = Self.entries(for: try await Self.artistSongs(id: id))
        }
        guard isCurrent() else { throw CancellationError() }
        guard !resolved.isEmpty else { throw Self.notFound("\(request)") }
        // The row that was clicked must play; if it couldn't be found, say so instead of
        // quietly starting another song.
        if let startURI, !resolved.contains(where: { $0.uri == startURI }) { throw Self.notFound(startURI) }
        let explicitBlocked = AppleMusicContentRestrictions.isExplicitMusicBlocked()
        if explicitBlocked {
            await Self.lookUpRatings(resolved.map(\.entry) + carriedAddedSongs().map(\.entry))
            guard isCurrent() else { throw CancellationError() }
        }
        let queueable = try Self.leavingOutBlocked(resolved, startURI: startURI, explicitBlocked: explicitBlocked)
        // No row was picked (an album, playlist or artist from its header): with shuffle on it
        // starts at a random song, like Spotify. Shuffle only reorders what comes after the
        // song that plays first, so that song moves to the front and every other one stays
        // ahead of it.
        let ordered = startURI == nil && shuffleWanted
            ? Self.movingToFront(queueable, index: Int.random(in: queueable.indices))
            : queueable
        let startIndex = ordered.firstIndex { $0.uri == startURI } ?? 0
        // Songs added with Add to queue that haven't played yet stay queued, right after the
        // new first song, like Spotify's queue. With shuffle off they go into the new queue
        // as it is set; with shuffle on MusicKit reshuffles a new queue, so they are inserted
        // after that instead, or they'd end up anywhere in it.
        // Songs added before the Mac started blocking explicit music are left out too.
        let carried = Self.droppingBlocked(carriedAddedSongs(), explicitBlocked: explicitBlocked)
        let carriedInQueue = shuffleWanted ? [] : carried
        var queued = ordered
        queued.insert(contentsOf: carriedInQueue, at: startIndex + 1)
        let current = RestorePoint(book: book, uris: uriByEntryKey)
        uriByEntryKey = [:]
        uriMapGeneration += 1
        for item in queued + (shuffleWanted ? carried : []) {
            remember(item.uri, for: item.entry)
        }
        book.replace(
            with: queued.map { AppleMusicQueueBook.Row(uri: $0.uri, title: $0.entry.title) },
            carryingAdded: carriedInQueue.count,
            after: startIndex
        )
        let ownBook = book
        let ownURIs = uriByEntryKey
        // MusicKit may only take the queue from the pressed song on.
        let played = { (leftOut: Int) -> RestorePoint in
            var book = ownBook
            book.dropFirst(leftOut)
            return RestorePoint(book: book, uris: ownURIs)
        }
        let started: AppleMusicQueueStarts<RestorePoint>.Started
        do {
            started = try await starts.start(
                queued.map(\.entry),
                at: startIndex,
                shuffles: shuffleWanted,
                currentRows: current,
                rowsPlayed: played
            )
        } catch let refused as AppleMusicQueueStarts<RestorePoint>.Refused {
            // MusicKit switched to the new queue before it refused to play it. What the player
            // holds now is what the start gave back (#476).
            switch refused.left {
            case let .previousQueue(rows, leftOutBefore):
                // Given back without the songs before the current one, every position moves up.
                book = rows.book
                book.forgetPendingAdds()
                book.dropFirst(leftOutBefore)
                uriByEntryKey = rows.uris
                applyModesToNewQueue()
            case .nothing:
                book = AppleMusicQueueBook()
                uriByEntryKey = [:]
            case .replaced:
                break
            }
            throw Self.mappedError(refused.underlying)
        }
        // The player switches to a queue it was given only once it plays, so shuffle, repeat
        // and (with shuffle on) the carried songs go in now. A queue that replaced this one
        // meanwhile (a newer play, or a stop) owns the player, its book and its rows: leave
        // them alone.
        guard starts.holdsQueue(started) else { return }
        // The book is still this queue's when MusicKit took it at once (an add may have finished
        // meanwhile). When it only took it from the pressed song on, the queue was set again: an
        // add that went into the refused one is gone with it, so the book is this queue's own,
        // moved up.
        if started.leftOut > 0 {
            book = played(started.leftOut).book
        }
        applyModesToNewQueue()
        if shuffleWanted, !carried.isEmpty {
            // Each goes right after the current song, so inserting the last first keeps the
            // order they were added in.
            for item in carried.reversed() {
                guard starts.holdsQueue(started) else { return }
                try await Self.mapped {
                    try await self.player.queue.insert(item.entry, position: .afterCurrentEntry)
                }
            }
            guard starts.holdsQueue(started) else { return }
            let entries = player.queue.entries
            if let current = player.queue.currentEntry,
               let currentIndex = entries.firstIndex(where: { $0.id == current.id }) {
                book.markAdded(start: currentIndex + 1, count: carried.count)
            }
        }
    }

    func pause() {
        player.pause()
        starts.paused()
    }

    func resume() async throws {
        try await Self.mapped { try await self.player.play() }
        starts.playerPlays()
    }

    func stop() {
        starts.stop()
        book = AppleMusicQueueBook()
        uriByEntryKey = [:]
        uriMapGeneration += 1
    }

    func seek(toMilliseconds milliseconds: Int) {
        player.playbackTime = TimeInterval(milliseconds) / 1000
    }

    func skipToNext() async throws {
        try await Self.mapped { try await self.player.skipToNextEntry() }
        starts.playerPlays()
    }

    func skipToPrevious() async throws {
        try await Self.mapped { try await self.player.skipToPreviousEntry() }
        starts.playerPlays()
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

    func enqueue(uri: String, isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard let resolved = try await Self.resolveEntries([uri]).first else { throw Self.notFound(uri) }
        let explicitBlocked = AppleMusicContentRestrictions.isExplicitMusicBlocked()
        if explicitBlocked { await Self.lookUpRatings([resolved.entry]) }
        _ = try Self.leavingOutBlocked([resolved], startURI: uri, explicitBlocked: explicitBlocked)
        // Signed out during the lookup: the queue belongs to the session that ended.
        guard isCurrent() else { throw CancellationError() }
        let rememberedKeys = remember(uri, for: resolved.entry)
        let rememberedIn = uriMapGeneration
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
            do {
                try await Self.mapped {
                    try await self.player.queue.insert(resolved.entry, position: .afterCurrentEntry)
                }
            } catch {
                // The song never joined the queue, so a later song with the same keys must
                // not show this row. A queue that replaced this one meanwhile keeps its own.
                if uriMapGeneration == rememberedIn {
                    for key in rememberedKeys { uriByEntryKey[key] = nil }
                }
                throw error
            }
        }
        book.finishAdd(plan)
    }

    func readState() -> AppleMusicPlayerState {
        // Media keys and Control Center reach MusicKit without the app: a refused queue that
        // plays after all shows.
        if starts.hidesRefusedQueue, player.state.playbackStatus == .playing {
            starts.playerReportsPlaying()
        }
        guard !starts.hidesRefusedQueue else {
            return AppleMusicPlayerState(
                status: .stopped,
                current: nil,
                positionMilliseconds: 0,
                shuffle: shuffleWanted,
                repeatMode: Self.repeatMode(repeatWanted)
            )
        }
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
        guard !starts.hidesRefusedQueue else { return [] }
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

    /// `items` with the one at `index` first and the others after it in their order.
    static func movingToFront<Item>(_ items: [Item], index: Int) -> [Item] {
        guard items.indices.contains(index) else { return items }
        var reordered = items
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    /// The first row URI queued under each of the entry's keys wins. Returns the keys it set.
    @discardableResult
    private func remember(_ uri: String, for entry: MusicPlayer.Queue.Entry) -> [String] {
        let added = Self.keys(entry).filter { uriByEntryKey[$0] == nil }
        for key in added {
            uriByEntryKey[key] = uri
        }
        return added
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

    // MARK: - Restrictions

    /// `items` without the songs this Mac won't play. A Mac that only allows clean music (Screen
    /// Time's Content & Privacy, or a profile from whoever manages it) makes MusicKit refuse to
    /// start an explicit song with "Failed to prepare to play" (#429), so they are left out and
    /// the rest of a list plays. The picked song being one of them, or every song of a list,
    /// fails with the reason instead.
    static func leavingOutBlocked(
        _ items: [(uri: String, entry: MusicPlayer.Queue.Entry)],
        startURI: String?,
        explicitBlocked: Bool
    ) throws -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        let kept = droppingBlocked(items, explicitBlocked: explicitBlocked)
        if let startURI, items.contains(where: { $0.uri == startURI }), !kept.contains(where: { $0.uri == startURI }) {
            throw explicitRestricted(startURI)
        }
        if kept.isEmpty, let first = items.first { throw explicitRestricted(first.uri) }
        return kept
    }

    /// `items` without the songs this Mac won't play, never failing: for songs that only come
    /// along (added with Add to queue before the restriction was turned on).
    static func droppingBlocked(
        _ items: [(uri: String, entry: MusicPlayer.Queue.Entry)],
        explicitBlocked: Bool
    ) -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        guard explicitBlocked else { return items }
        return items.filter { !isExplicit($0.entry) }
    }

    /// Saved songs have no rating of their own on macOS; their catalog release's counts, looked
    /// up by ``lookUpRatings(_:)`` (#518).
    private static func isExplicit(_ entry: MusicPlayer.Queue.Entry) -> Bool {
        switch entry.item {
        case let .song(song): AppleMusicContentRatings.shared.isExplicit(song)
        case let .musicVideo(video): video.contentRating == .explicit
        case nil: false
        @unknown default: false
        }
    }

    /// Looks up the catalog rating of the saved songs among `entries` that no list has shown yet.
    private static func lookUpRatings(_ entries: [MusicPlayer.Queue.Entry]) async {
        let songs = entries.compactMap { entry -> Song? in
            if case let .song(song) = entry.item { return song }
            return nil
        }
        await AppleMusicContentRatings.shared.resolve(songs) { try await MusicKitContentSource.catalogSongRatings(catalogIDs: $0) }
    }

    private static func explicitRestricted(_ uri: String) -> MusicPlaybackError {
        MusicPlaybackError(
            service: .appleMusic,
            reason: .explicitContentRestricted,
            detail: "\(uri) is explicit and this Mac only allows clean music"
        )
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
        } catch {
            throw mappedError(error)
        }
    }

    /// A MusicKit failure as the ``MusicPlaybackError`` (or cancellation) the provider passes on.
    private static func mappedError(_ error: Error) -> Error {
        switch error {
        case let error as MusicPlaybackError:
            return error
        case is CancellationError:
            return CancellationError()
        case let error as MusicTokenRequestError:
            switch error {
            case .permissionDenied, .userTokenRevoked, .userNotSignedIn:
                return MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: String(describing: error))
            default:
                return MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
            }
        case let error as URLError:
            return MusicPlaybackError(service: .appleMusic, reason: .network(error.localizedDescription), detail: String(describing: error))
        default:
            return playerError(error)
        }
    }

    /// The error domain of MusicKit's player. Its code 6, "Failed to prepare to play", means the
    /// player refused the song itself (not available here, or restricted): trying again gives
    /// the same answer, so it reads as "can't play this" rather than "try again".
    static let playerErrorDomain = "MPMusicPlayerControllerErrorDomain"
    static let prepareToPlayFailedCode = 6

    static func playerError(_ error: Error) -> MusicPlaybackError {
        let nsError = error as NSError
        let reason: MusicPlaybackError.Reason = nsError.domain == playerErrorDomain && nsError.code == prepareToPlayFailedCode
            ? .notFound
            : .failed
        return MusicPlaybackError(service: .appleMusic, reason: reason, detail: String(describing: error))
    }
}

/// The part of MusicKit's player that starting a queue uses. ``MusicKitQueueStarter`` is the
/// live one; tests use a player that refuses queues the way MusicKit does.
@MainActor
protocol AppleMusicQueueStarting: AnyObject {
    var entries: [MusicPlayer.Queue.Entry] { get }
    var currentEntry: MusicPlayer.Queue.Entry? { get }
    var isPlaying: Bool { get }
    var playbackTime: TimeInterval { get set }
    /// `startingAt` nil starts at the first entry without naming it.
    func setQueue(_ entries: [MusicPlayer.Queue.Entry], startingAt entry: MusicPlayer.Queue.Entry?)
    func play() async throws
    func prepareToPlay() async throws
    func pause()
    func stop()
}

/// Starts a new queue at the pressed song, and gives back what was there when MusicKit refuses.
///
/// Two things MusicKit does on macOS (measured on macOS 27 for #476):
/// - A queue that names the song to start at is refused about half the time when it is short
///   (one or two songs: a search result, a single row), with `MPMusicPlayerControllerErrorDomain`
///   6, "Prepare queue failed with unexpected start item". The same songs queued without naming
///   a start (it then starts at the first) played every time, and a second try with fresh
///   entries played too. So the start is named only when the pressed song isn't first, and a
///   refused start tries once more with the queue beginning at the pressed song.
/// - With shuffle on, a queue of several songs that doesn't name its start starts on a random
///   one (seen in the app: the first row pressed played the twelfth). Then the start is always
///   named, and a refused one tries once more, named, with fresh entries.
/// - MusicKit takes the new queue before it tries to play it. When it refuses, the refused song
///   stays the current entry, paused at 0:00, and what was playing has stopped: the bar showed
///   the song the user had just pressed play on as "Paused". So a start that is refused for good
///   gives back what last played, at the same song and position, playing if it was playing,
///   and stops the player when there is nothing to give back.
///
/// Starts can overlap: a press made while MusicKit still works on the one before. A start owns
/// the player's queue until another queue replaces it (or the player is stopped), not until the
/// next press: a newer press may still be looking up its songs. A queue the player holds but
/// hasn't played is never given back. `Rows` is what the caller keeps about a queue (the rows
/// behind its songs); it comes back with the queue.
@MainActor
final class AppleMusicQueueStarts<Rows> {
    /// What the player holds after a refused start.
    enum Left {
        /// What last played, at the same song, with its `rows`. `leftOutBefore` is how many of
        /// its songs before that one had to be left out for MusicKit to take it back.
        case previousQueue(rows: Rows, leftOutBefore: Int)
        /// Nothing could be given back: the player is stopped and shows nothing loaded.
        case nothing
        /// Another queue replaced this one meanwhile (a newer play, or a stop): it was left alone.
        case replaced
    }

    struct Refused: Error, @unchecked Sendable {
        let underlying: Error
        let left: Left
    }

    /// A start MusicKit took. `leftOut` is how many songs before the pressed one were left out
    /// (0, or the pressed song's position when MusicKit only took the queue from it on).
    struct Started {
        let leftOut: Int
        fileprivate let queueSerial: Int
    }

    /// Set when a start was refused with nothing to give back: MusicKit still holds the refused
    /// queue, stopped, but nothing played, so the bar shows nothing loaded instead of that song
    /// as "Paused". A queue that plays clears it.
    private(set) var hidesRefusedQueue = false
    /// When the refused queue was hidden. MusicKit's state trails commands by up to a third of a
    /// second, so for a moment it can still report the music it was playing before.
    private var hiddenAt: Date?
    /// How long a "playing" report right after hiding is taken for that trailing state.
    static var reportSettle: TimeInterval { 1 }

    private let player: any AppleMusicQueueStarting
    /// Bumped whenever the player's queue is replaced or the player is stopped.
    private var queueSerial = 0
    /// Whether shuffle is on: set by every start, since it decides how queues are set.
    private var shuffles = false
    /// The ``queueSerial`` of the last stop. A start that MusicKit plays after it stops again,
    /// and what a stopped player holds (an ended session's queue) is nothing to give back.
    private var stoppedAt: Int?
    /// What a refused start gives back, shared by the starts whose queue the player holds but
    /// hasn't played yet; `nil` once what the player holds played.
    private var pending: GiveBack?

    private final class GiveBack {
        var entries: [MusicPlayer.Queue.Entry]
        var index: Int?
        var wasPlaying: Bool
        var time: TimeInterval
        var rows: Rows
        /// I paused while the start waited: what it plays after that is paused again.
        var pausedMeanwhile = false

        init(entries: [MusicPlayer.Queue.Entry], index: Int?, wasPlaying: Bool, time: TimeInterval, rows: Rows) {
            self.entries = entries
            self.index = index
            self.wasPlaying = wasPlaying
            self.time = time
            self.rows = rows
        }
    }

    init(player: any AppleMusicQueueStarting) {
        self.player = player
    }

    /// Whether the queue of `started` is still the player's.
    func holdsQueue(_ started: Started) -> Bool {
        started.queueSerial == queueSerial
    }

    /// The player plays what it holds (a resume, a skip, or a media key that went straight to
    /// MusicKit), so it shows again.
    func playerPlays() {
        hidesRefusedQueue = false
    }

    /// MusicKit reports playing while the refused queue is hidden: something started it without
    /// the app (a media key, Control Center). Right after hiding, that is only its state
    /// trailing the stop.
    func playerReportsPlaying(now: Date = Date()) {
        guard let hiddenAt, now.timeIntervalSince(hiddenAt) >= Self.reportSettle else { return }
        playerPlays()
    }

    /// I paused while a start waits for MusicKit: if it is refused, what it gives back stays
    /// paused.
    func paused() {
        pending?.wasPlaying = false
        pending?.pausedMeanwhile = true
    }

    /// Stops the player. A start still waiting for MusicKit then leaves the queue alone.
    func stop() {
        player.stop()
        queueSerial += 1
        stoppedAt = queueSerial
        pending = nil
    }

    /// Another queue or a stop replaced the start that just heard back from MusicKit. After a
    /// stop, what MusicKit started anyway is stopped again.
    private func replaced(playing: Bool) {
        if playing, stoppedAt == queueSerial {
            player.stop()
        }
    }

    /// Plays `entries` from `startIndex`. `currentRows` are the rows of what the player holds
    /// now; `rowsPlayed` gives this queue's rows once it is known how many songs were left out.
    func start(
        _ entries: [MusicPlayer.Queue.Entry],
        at startIndex: Int,
        shuffles: Bool = false,
        currentRows: Rows,
        rowsPlayed: (Int) -> Rows
    ) async throws -> Started {
        guard entries.indices.contains(startIndex) else {
            throw MusicPlaybackError(service: .appleMusic, reason: .notFound, detail: "No song at queue position \(startIndex)")
        }
        self.shuffles = shuffles
        let giveBack = pending ?? giveBackNow(rows: currentRows)
        pending = giveBack
        var refusal: Error
        var mine = setQueue(entries, at: startIndex)
        do {
            try await player.play()
            return played(Array(entries), at: startIndex, leftOut: 0, serial: mine, giveBack: giveBack, rowsPlayed: rowsPlayed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            refusal = error
        }
        guard mine == queueSerial else { throw Refused(underlying: refusal, left: .replaced) }
        if let retry = retry(entries, at: startIndex) {
            mine = setQueue(retry.entries, at: retry.index)
            do {
                try await player.play()
                if giveBack.pausedMeanwhile, mine == queueSerial { player.pause() }
                return played(retry.entries, at: retry.index, leftOut: retry.leftOut, serial: mine, giveBack: giveBack, rowsPlayed: rowsPlayed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                refusal = error
            }
            guard mine == queueSerial else { throw Refused(underlying: refusal, left: .replaced) }
        }
        try await giveBackOrStop(giveBack, refusal: refusal)
    }

    /// Gives back what last played: a song that was playing plays on, a paused one is loaded
    /// and stays paused, either at its position. Always throws ``Refused``.
    private func giveBackOrStop(_ giveBack: GiveBack, refusal: Error) async throws -> Never {
        guard let index = giveBack.index else { try stopRefused(refusal) }
        var mine = setQueue(Self.fresh(giveBack.entries), at: index)
        var leftOut = 0
        // A pause while it loads turns `wasPlaying` off: it is paused again once loaded.
        let loadsPlaying = giveBack.wasPlaying
        // Set before it plays too, so the song isn't heard from 0:00 first; set again once it
        // does, in case MusicKit only takes it then.
        player.playbackTime = giveBack.time
        do {
            try await load(playing: loadsPlaying)
        } catch {
            guard mine == queueSerial else { throw Refused(underlying: refusal, left: .replaced) }
            guard let retry = retry(giveBack.entries, at: index) else { try stopRefused(refusal) }
            mine = setQueue(retry.entries, at: retry.index)
            leftOut = retry.leftOut
            player.playbackTime = giveBack.time
            do {
                try await load(playing: loadsPlaying)
            } catch {
                guard mine == queueSerial else { throw Refused(underlying: refusal, left: .replaced) }
                try stopRefused(refusal)
            }
        }
        guard mine == queueSerial else {
            replaced(playing: giveBack.wasPlaying)
            throw Refused(underlying: refusal, left: .replaced)
        }
        player.playbackTime = giveBack.time
        if loadsPlaying, !giveBack.wasPlaying { player.pause() }
        pending = nil
        hidesRefusedQueue = false
        throw Refused(underlying: refusal, left: .previousQueue(rows: giveBack.rows, leftOutBefore: leftOut))
    }

    private func played(
        _ entries: [MusicPlayer.Queue.Entry],
        at index: Int,
        leftOut: Int,
        serial: Int,
        giveBack: GiveBack,
        rowsPlayed: (Int) -> Rows
    ) -> Started {
        if serial == queueSerial {
            pending = nil
            hidesRefusedQueue = false
        } else if stoppedAt == queueSerial {
            replaced(playing: true)
        } else {
            // A newer start replaced this queue while it was starting. This one played, so it
            // is what that start gives back if MusicKit refuses it.
            giveBack.entries = entries
            giveBack.index = index
            giveBack.wasPlaying = true
            giveBack.time = 0
            giveBack.rows = rowsPlayed(leftOut)
        }
        return Started(leftOut: leftOut, queueSerial: serial)
    }

    /// What the player holds now, as a give-back. A refused queue that is only hidden, or the
    /// queue of a stopped player, is nothing to give back.
    private func giveBackNow(rows: Rows) -> GiveBack {
        guard !hidesRefusedQueue, stoppedAt != queueSerial else {
            return GiveBack(entries: [], index: nil, wasPlaying: false, time: 0, rows: rows)
        }
        let entries = player.entries
        return GiveBack(
            entries: entries,
            index: player.currentEntry.flatMap { current in entries.firstIndex { $0.id == current.id } },
            wasPlaying: player.isPlaying,
            time: player.playbackTime,
            rows: rows
        )
    }

    /// Nothing could be given back: stops the refused queue and hides it.
    private func stopRefused(_ refusal: Error) throws -> Never {
        stop()
        hidesRefusedQueue = true
        hiddenAt = Date()
        throw Refused(underlying: refusal, left: .nothing)
    }

    /// The second try after MusicKit refused `entries` from `index`: with shuffle on the same
    /// songs, fresh and named again; else the songs from the pressed one on, so its start needn't
    /// be named. `nil` when there is nothing else to try.
    private func retry(
        _ entries: [MusicPlayer.Queue.Entry],
        at index: Int
    ) -> (entries: [MusicPlayer.Queue.Entry], index: Int, leftOut: Int)? {
        if shuffles, entries.count > 1 { return (Self.fresh(entries), index, 0) }
        guard index > 0 else { return nil }
        return (Self.fresh(Array(entries[index...])), 0, index)
    }

    /// Sets the queue, naming the start only when it isn't the first entry, or with shuffle on,
    /// when there is more than one.
    private func setQueue(_ entries: [MusicPlayer.Queue.Entry], at index: Int) -> Int {
        let names = index > 0 || (shuffles && entries.count > 1)
        player.setQueue(entries, startingAt: names ? entries[index] : nil)
        queueSerial += 1
        return queueSerial
    }

    private func load(playing: Bool) async throws {
        if playing {
            try await player.play()
        } else {
            try await player.prepareToPlay()
        }
    }

    /// New entries for the same items: MusicKit gives the entries of a queue it was handed new
    /// ids, so the ones it already had can't name a start again.
    static func fresh(_ entries: [MusicPlayer.Queue.Entry]) -> [MusicPlayer.Queue.Entry] {
        entries.map { entry in
            switch entry.item {
            case let .song(song): MusicPlayer.Queue.Entry(song)
            // The player never queues music videos on macOS (``resolveEntries``).
            default: entry
            }
        }
    }
}

/// ``AppleMusicQueueStarting`` on MusicKit's `ApplicationMusicPlayer`.
@MainActor
final class MusicKitQueueStarter: AppleMusicQueueStarting {
    private let player: ApplicationMusicPlayer

    init(player: ApplicationMusicPlayer) {
        self.player = player
    }

    var entries: [MusicPlayer.Queue.Entry] { Array(player.queue.entries) }
    var currentEntry: MusicPlayer.Queue.Entry? { player.queue.currentEntry }

    var isPlaying: Bool {
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: true
        default: false
        }
    }

    var playbackTime: TimeInterval {
        get { player.playbackTime }
        set { player.playbackTime = newValue }
    }

    func setQueue(_ entries: [MusicPlayer.Queue.Entry], startingAt entry: MusicPlayer.Queue.Entry?) {
        player.queue = entry.map { ApplicationMusicPlayer.Queue(entries, startingAt: $0) }
            ?? ApplicationMusicPlayer.Queue(entries)
    }

    func play() async throws { try await player.play() }
    func prepareToPlay() async throws { try await player.prepareToPlay() }
    func pause() { player.pause() }
    func stop() { player.stop() }
}

/// Whether this Mac only allows clean music. Screen Time's Content & Privacy ("Music, Podcasts,
/// Fitness: Clean") writes `restrictExplicit` into the managed `com.apple.iTunes` preferences;
/// a restrictions profile from whoever manages the Mac sets `allowExplicitContent` to false.
/// Only enforced (managed) values count: the same keys saved as ordinary preferences, say left
/// over from an old iTunes, don't stop MusicKit from playing anything.
enum AppleMusicContentRestrictions {
    /// A preference's value and whether Screen Time or a profile enforces it.
    typealias Lookup = @Sendable (_ key: String, _ domain: String) -> (value: Any?, isForced: Bool)

    static func isExplicitMusicBlocked(lookup: Lookup = live) -> Bool {
        let restrict = lookup("restrictExplicit", "com.apple.iTunes")
        if restrict.isForced, restrict.value as? Bool == true { return true }
        let allow = lookup("allowExplicitContent", "com.apple.applicationaccess")
        return allow.isForced && allow.value as? Bool == false
    }

    /// Read fresh on every call: the restriction can change while the app runs.
    static let live: Lookup = { key, domain in
        let domain = domain as CFString
        let key = key as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain), CFPreferencesAppValueIsForced(key, domain))
    }
}
