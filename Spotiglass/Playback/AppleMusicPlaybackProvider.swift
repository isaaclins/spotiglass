import Foundation

/// What the Apple Music provider starts. URIs are the `applemusic:<kind>:<id>` references the
/// Apple Music browsing provider hands out.
enum AppleMusicQueueRequest: Equatable {
    /// An explicit list of songs or music videos, starting at `startURI` (the first when nil).
    case items(uris: [String], startURI: String?)
    case album(id: String)
    case playlist(id: String)
    /// An artist's songs: the catalog's top songs, or the songs of a library artist.
    case artist(id: String)
}

/// Shuffle, repeat, the item and the position, read from MusicKit's player in service-neutral
/// types. What comes next is read on its own (``AppleMusicPlayerControlling/readUpcoming()``):
/// the session reads this every second and only needs the queue when the queue panel asks.
struct AppleMusicPlayerState: Equatable {
    enum Status: Equatable {
        case playing
        case paused
        /// Stopped, interrupted or never started.
        case stopped
    }

    var status: Status
    /// `nil` when the queue is empty.
    var current: MusicTrack?
    var positionMilliseconds: Int
    var shuffle: Bool
    var repeatMode: MusicRepeatMode
}

/// The seam between the provider and MusicKit's `ApplicationMusicPlayer`.
/// ``MusicKitApplicationPlayer`` is the live implementation; tests use a scripted player.
@MainActor
protocol AppleMusicPlayerControlling: AnyObject {
    /// Whether this app may use Apple Music (the system's Media & Apple Music permission).
    func isAuthorized() -> Bool
    /// Replaces the queue and starts playing it. A request's songs are looked up first, which
    /// can take a while; when `isCurrent()` is false once they are, a newer play has started,
    /// and this throws `CancellationError` and leaves the queue alone.
    func play(_ request: AppleMusicQueueRequest, isCurrent: @escaping @MainActor () -> Bool) async throws
    func pause()
    func resume() async throws
    /// Stops playback. MusicKit keeps the queue; the songs added to it with Add to Queue are
    /// forgotten, so a new play doesn't carry them over from the session that ended.
    func stop()
    func seek(toMilliseconds milliseconds: Int)
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setShuffle(_ enabled: Bool)
    func setRepeat(_ mode: MusicRepeatMode)
    /// Adds an item after the current one and after the items added before it, like
    /// Spotify's "Add to queue". `isCurrent` is asked once the lookup is done: an add from a
    /// session that ended meanwhile leaves the queue alone.
    func enqueue(uri: String, isCurrent: @escaping @MainActor () -> Bool) async throws
    /// Adds an item at the very end of the queue, after everything queued (Autoplay, #613).
    func append(uri: String, isCurrent: @escaping @MainActor () -> Bool) async throws
    func readState() -> AppleMusicPlayerState
    /// The entries after the current one, in play order.
    func readUpcoming() -> [MusicTrack]
    /// Takes the entries at these places in ``readUpcoming()`` out of the queue (#628) and keeps
    /// them under the receipt's id for ``restoreUpcoming(_:)``. Places past the end are left out.
    func removeUpcoming(at positions: [Int]) -> QueueRemovalReceipt
    /// Puts the entries of a removal back at their places, counted from the current entry.
    func restoreUpcoming(_ receipt: QueueRemovalReceipt) throws
}

/// Apple Music behind ``MusicPlaybackProvider``, played by MusicKit's `ApplicationMusicPlayer`.
///
/// There is one player, this Mac, so it reports one constant device id, has no device
/// transfer, nothing to reload and no pushed state: the session reads the player on its poll
/// cadence and confirms commands with the settle window from ``MusicPlaybackCapabilities``.
/// Apple's player publishes Now Playing (Control Center, media keys) itself, so this provider
/// never writes `MPNowPlayingInfoCenter`.
///
/// MusicKit has no volume for the application player, so the provider does not declare
/// ``MusicPlaybackCapabilities/playerVolume`` and the volume slider is hidden; the Mac's own
/// volume applies.
@MainActor
final class AppleMusicPlaybackProvider: MusicPlaybackProvider {
    /// The one in-app player's id. Opaque to the session.
    static let deviceID = "apple-music-this-mac"

    let service: MusicService = .appleMusic
    let capabilities: MusicPlaybackCapabilities = []
    var eventHandler: ((MusicPlaybackEventEnvelope) -> Void)?

    private let player: any AppleMusicPlayerControlling
    /// Bumped by every play, so only the latest one replaces the queue.
    private var playGeneration: UInt64 = 0
    /// The last "Add to queue" still running. Adds run one after another, so they land in the
    /// order they were made even when one waits for a lookup.
    private var enqueueTail: Task<Void, Never>?
    /// The latest play while it runs. An add made after it waits for it, so the song goes into
    /// the queue that play starts instead of the one it is about to replace.
    private var latestPlay: Task<Void, Never>?
    /// Set by a disconnect, cleared once the next play went through: the queue MusicKit still
    /// holds is from the session that ended, and a play that fails leaves it there. Add to
    /// Queue doesn't clear it (there's nothing loaded to add after,
    /// ``PlaybackSessionViewModel/hasNothingLoaded``), or the old songs would return.
    ///
    /// Set from the start too: MusicKit hands back the queue of the app's last launch, its
    /// library songs under persistent ids (`applemusic:song:-1993878998138392367`), and
    /// `play()` on it returns without an error and without playing. Showing that song would
    /// offer a play button that does nothing (#586), so a launch starts with nothing loaded.
    private var isSessionEnded = true
    /// Bumped by every disconnect: an add still looking up its song when the session ended
    /// leaves the queue alone.
    private var session: UInt64 = 0
    /// The generation of the play still running, if the latest play hasn't finished yet.
    private var runningPlayGeneration: UInt64?
    /// Queue reads waiting for the latest play. A newer play takes them over, so a read never
    /// waits for a play that was replaced (#413).
    private var queueReadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The longest a queue read waits for a play. A play that never finishes (a stalled
    /// lookup) must not hold the queue panel on "loading" for good; the read then shows what
    /// the player has.
    private let queueReadWaitLimit: Duration

    var isQueueSettling: Bool { runningPlayGeneration != nil }

    init(player: (any AppleMusicPlayerControlling)? = nil, queueReadWaitLimit: Duration = .seconds(15)) {
        self.player = player ?? MusicKitApplicationPlayer()
        self.queueReadWaitLimit = queueReadWaitLimit
    }

    // MARK: - Player lifecycle

    func loadPlayer(generation: PlaybackHostGeneration) {}

    func connectPlayer(generation: PlaybackHostGeneration) async throws {
        guard player.isAuthorized() else {
            throw MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: "Apple Music access is off")
        }
        eventHandler?(MusicPlaybackEventEnvelope(event: .ready(deviceID: Self.deviceID), hostGeneration: generation))
    }

    /// Disconnecting ends the session (signing out of Apple Music, #396): the music stops, so
    /// nothing keeps playing that the window can't control, and the stopped song is forgotten,
    /// so adding Apple Music again starts with nothing loaded instead of the old song.
    /// MusicKit keeps its queue after `stop()` (an empty queue assigned to it is ignored), so the
    /// provider stops reporting it until something new plays. A play still looking up its
    /// songs belongs to the session that ended too: moving the generation on keeps it from
    /// starting once its lookup returns.
    func disconnectPlayer(generation: PlaybackHostGeneration) async throws {
        // Its stop isn't any button's: name why it happens.
        PlaybackTrace.shared.request(
            "end the Apple Music session (sign-out, service switch or player reset)", file: #fileID, line: #line
        )
        playGeneration &+= 1
        session &+= 1
        runningPlayGeneration = nil
        releaseQueueReads()
        player.stop()
        isSessionEnded = true
    }

    // MARK: - Commands for a device

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws {
        playGeneration &+= 1
        let generation = playGeneration
        let queueRequest = try Self.queueRequest(for: request)
        let session = session
        let run = Task { @MainActor [weak self, player] in
            try await player.play(queueRequest, isCurrent: { [weak self] in self?.playGeneration == generation })
            // A play that returns has set its queue, so the ended session's songs are gone,
            // even if a newer play is on its way. Cleared here, inside the play, so an add
            // waiting for it (``latestPlay``) sees it; a play that failed leaves the old queue
            // hidden, and one that outlived a sign-out doesn't count.
            if let self, self.session == session { self.isSessionEnded = false }
        }
        runningPlayGeneration = generation
        latestPlay = Task { [weak self] in
            _ = await run.result
            self?.playFinished(generation: generation)
        }
        try await perform { try await run.value }
    }

    func pause(deviceID: String) async throws {
        player.pause()
    }

    func resume(deviceID: String) async throws {
        try await resumePlayer()
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        player.seek(toMilliseconds: max(0, milliseconds))
    }

    func skipToNext(deviceID: String) async throws {
        try await perform { try await player.skipToNext() }
    }

    func skipToPrevious(deviceID: String) async throws {
        try await perform { try await player.skipToPrevious() }
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        player.setShuffle(enabled)
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        player.setRepeat(mode)
    }

    func enqueue(uri: String, deviceID: String) async throws {
        try await add(uri: uri, atEnd: false, isWanted: { true })
    }

    func appendToQueueEnd(_ track: MusicTrack, deviceID: String, isWanted: @escaping @MainActor () -> Bool) async throws {
        try await add(uri: track.uri, atEnd: true, isWanted: isWanted, identity: QueueAutoplayIdentity.keys(track))
    }

    /// `identity` (Autoplay's adds only): the song's keys, to leave it out when any copy of it
    /// was queued while this add waited its turn.
    private func add(
        uri: String,
        atEnd: Bool,
        isWanted: @escaping @MainActor () -> Bool,
        identity: Set<String> = []
    ) async throws {
        // The session refuses an add while nothing is loaded. An add that still slips in after
        // a sign-out (made before it, or racing it) leaves the queue alone: it waits for the
        // play before it, and once its lookup is done it checks that the session is still the
        // one it was made in and that something was played since.
        let previous = enqueueTail
        let pendingPlay = latestPlay
        let session = session
        let add = Task { @MainActor [player] in
            await pendingPlay?.value
            await previous?.value
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.session == session && !self.isSessionEnded && isWanted()
            }
            if atEnd {
                // An add waiting its turn behind one made by hand finds that one queued now,
                // whichever copy of the song it was.
                if player.readUpcoming().contains(where: { !QueueAutoplayIdentity.keys($0).isDisjoint(with: identity) }) {
                    throw QueueAppendSkipped.alreadyQueued
                }
                try await player.append(uri: uri, isCurrent: isCurrent)
            } else {
                try await player.enqueue(uri: uri, isCurrent: isCurrent)
            }
        }
        enqueueTail = Task { _ = await add.result }
        try await perform { try await add.value }
    }

    // MARK: - Queue editing

    /// Edits wait for the play and the adds before them, like an add, so they work on the
    /// queue the listener saw once those are in.
    private func edit<Result>(_ change: @escaping @MainActor () throws -> Result) async throws -> Result {
        let previous = enqueueTail
        let pendingPlay = latestPlay
        let session = session
        let run = Task { @MainActor [weak self] () throws -> Result in
            await pendingPlay?.value
            await previous?.value
            guard let self, self.session == session, !self.isSessionEnded else { throw CancellationError() }
            return try change()
        }
        enqueueTail = Task { _ = await run.result }
        var result: Result?
        try await perform { result = try await run.value }
        guard let result else { throw CancellationError() }
        return result
    }

    // MARK: - Commands for the in-app player

    /// The session uses explicit pause / resume for a player without pushed state; this is
    /// only reached by callers that toggle directly.
    func togglePlayPause(commandID: UInt64?) async throws {
        if player.readState().status == .playing {
            player.pause()
        } else {
            try await resumePlayer()
        }
    }

    func setInAppPlayerPlaying(_ playing: Bool, commandID: UInt64?) async throws {
        if playing {
            try await resumePlayer()
        } else {
            player.pause()
        }
    }

    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws {}

    /// Resumes the queue a play of this session set. MusicKit's leftover queue (a session that
    /// ended, or the last launch) never plays on `play()` and never says so, so resuming it
    /// fails out loud instead of staying paused (#586).
    private func resumePlayer() async throws {
        guard !isSessionEnded else {
            throw MusicPlaybackError(service: .appleMusic, reason: .notFound, detail: "Nothing to resume: no song was started since Apple Music connected")
        }
        try await perform { try await player.resume() }
    }

    // MARK: - Reads

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
        guard !isSessionEnded else { return nil }
        let state = player.readState()
        guard let current = state.current else { return nil }
        return MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: state.shuffle, repeatMode: state.repeatMode),
            activeDevice: nil,
            isPlaying: state.status == .playing,
            item: .track(current),
            progressMilliseconds: state.positionMilliseconds
        )
    }

    /// A play still looking up its songs hasn't handed the player its queue yet, so a read
    /// then would return the old queue (or none). The read waits for the latest play, so a panel
    /// opened right after starting a long list shows the list it started (#413).
    func fetchQueue() async throws -> MusicPlaybackQueue {
        await waitForLatestPlay()
        guard !isSessionEnded else { return MusicPlaybackQueue(queue: []) }
        return MusicPlaybackQueue(queue: player.readUpcoming().map { .track($0) })
    }

    /// Only the latest play's end lets the queue reads go: a replaced play finishing late (or
    /// still looking up its songs) leaves them waiting for the play that replaced it.
    private func playFinished(generation: UInt64) {
        guard runningPlayGeneration == generation else { return }
        runningPlayGeneration = nil
        releaseQueueReads()
    }

    /// Waits until the latest play is in, the read is cancelled, the player disconnects or
    /// ``queueReadWaitLimit`` passes, whichever comes first.
    private func waitForLatestPlay() async {
        guard runningPlayGeneration != nil, !Task.isCancelled else { return }
        let id = UUID()
        let limit = queueReadWaitLimit
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queueReadWaiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.releaseQueueRead(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseQueueRead(id) }
        }
    }

    private func releaseQueueRead(_ id: UUID) {
        queueReadWaiters.removeValue(forKey: id)?.resume()
    }

    private func releaseQueueReads() {
        let waiters = queueReadWaiters
        queueReadWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }

    // MARK: - Mapping

    /// Which MusicKit queue a play request becomes. Context URIs name their kind; anything
    /// that isn't an Apple Music reference can't be played here.
    static func queueRequest(for request: MusicPlaybackRequest) throws -> AppleMusicQueueRequest {
        switch request {
        case let .item(uri):
            guard reference(uri) != nil else { throw notPlayable(uri) }
            return .items(uris: [uri], startURI: uri)
        case let .items(uris, startURI):
            let playable = uris.filter { reference($0) != nil }
            guard !playable.isEmpty else { throw notPlayable(startURI ?? uris.first ?? "") }
            return .items(uris: playable, startURI: startURI.flatMap { playable.contains($0) ? $0 : nil })
        case let .context(uri):
            guard let (kind, id) = reference(uri) else { throw notPlayable(uri) }
            switch kind {
            case "album": return .album(id: id)
            case "playlist": return .playlist(id: id)
            case "artist": return .artist(id: id)
            case "song", "music-video", "track": return .items(uris: [uri], startURI: uri)
            default: throw notPlayable(uri)
            }
        }
    }

    /// `(kind, id)` of an `applemusic:<kind>:<id>` URI.
    static func reference(_ uri: String) -> (kind: String, id: String)? {
        let parts = uri.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == AppleMusicItemMapping.uriScheme, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    private static func notPlayable(_ uri: String) -> MusicPlaybackError {
        MusicPlaybackError(service: .appleMusic, reason: .notFound, detail: "Not an Apple Music item: \(uri)")
    }

    /// Every failure leaves this provider as a ``MusicPlaybackError`` naming Apple Music.
    private func perform(_ command: () async throws -> Void) async throws {
        do {
            try await command()
        } catch let error as MusicPlaybackError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let skipped as QueueAppendSkipped {
            throw skipped
        } catch {
            throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
        }
    }
}

/// Apple Music can take songs out of its queue: MusicKit's queue entries are a mutable list.
extension AppleMusicPlaybackProvider: MusicQueueEditing {
    var queueEditing: (any MusicQueueEditing)? { self }

    func removeFromQueue(_ removals: [QueueRemoval], seenUpcoming: [String?]) async throws -> QueueRemovalReceipt {
        try await edit { [player] in
            let positions = QueueRemovalPlan.positions(
                for: removals,
                upcomingURIs: player.readUpcoming().map(\.uri),
                seenURIs: seenUpcoming
            )
            return player.removeUpcoming(at: positions)
        }
    }

    func clearUpcomingQueue() async throws -> QueueRemovalReceipt {
        try await edit { [player] in
            player.removeUpcoming(at: Array(player.readUpcoming().indices))
        }
    }

    func restoreToQueue(_ receipt: QueueRemovalReceipt) async throws {
        try await edit { [player] in try player.restoreUpcoming(receipt) }
    }
}

/// What the Apple Music player keeps about the queue it built: which row sits at each queue
/// position, and where the songs added with "Add to queue" are.
///
/// MusicKit's queue entries don't keep their ids (an inserted entry gets a temporary one that
/// is replaced moments later), but played entries keep their positions, so both are kept as
/// positions. The rules live here, apart from MusicKit, so the tests run them as they are.
struct AppleMusicQueueBook: Equatable {
    /// A queued song's row, as the player queued it.
    struct Row: Equatable {
        let uri: String
        let title: String
    }

    /// The run of added songs: `count` entries from queue position `start`.
    struct AddedRun: Equatable {
        var start: Int
        var count: Int
    }

    /// Where an add goes, decided before MusicKit inserts it.
    struct AddPlan: Equatable {
        /// The queue position for the new entry; `nil` when nothing is current, so MusicKit's
        /// own insert starts a queue.
        let index: Int?
        /// Whether `index` is right after the current entry (MusicKit's `.afterCurrentEntry`).
        let isAfterCurrent: Bool
        fileprivate let row: Row
        fileprivate let entryCount: Int
        fileprivate let rowsMatchQueue: Bool
        fileprivate let added: AddedRun?
        fileprivate let generation: UInt64
    }

    /// The row behind each queue position; empty once the queue changed in a way the player
    /// didn't make or can't follow.
    private(set) var rows: [Row] = []
    /// Rows by queue entry id, noted while positions held. Shuffle reorders the queue but
    /// keeps the ids of the entries already there, so after it the id still finds the row
    /// where only title, artist and length are left.
    private(set) var rowsByEntryID: [String: Row] = [:]
    private(set) var added: AddedRun?
    /// Bumped whenever the queue is replaced or its order can't be trusted, so an add that
    /// finishes after that doesn't write stale positions.
    private(set) var generation: UInt64 = 0

    /// A play replaced the queue with `rows`.
    mutating func replace(with rows: [Row]) {
        self.rows = rows
        rowsByEntryID = [:]
        added = nil
        generation &+= 1
    }

    /// Notes the ids of the queue's entries, in queue order, for the positions that still
    /// name their row. Run before anything reorders the queue (shuffle) and on reads.
    mutating func noteEntries(ids: [String], titles: [String]) {
        // When every entry's row is known by id, the ids give the positions back, also
        // after shuffle reordered the queue, so later adds and reads work by position again.
        let known = ids.compactMap { rowsByEntryID[$0] }
        if !ids.isEmpty, known.count == ids.count, zip(known, titles).allSatisfy({ $0.title == $1 }) {
            rows = known
            return
        }
        for (index, id) in ids.enumerated() where titles.indices.contains(index) {
            guard rows.indices.contains(index), rows[index].title == titles[index] else { continue }
            rowsByEntryID[id] = rows[index]
        }
    }

    /// The queue positions of the added songs that haven't played yet. A new play keeps them,
    /// right after its first song, like Spotify's queue.
    func addedAhead(of currentIndex: Int?) -> Range<Int>? {
        guard let added, let currentIndex else { return nil }
        let lower = max(added.start, currentIndex + 1)
        let upper = added.start + added.count
        // Playback past the added songs leaves none ahead (and lower > upper).
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// A play replaced the queue with `rows` and kept `carriedCount` added songs right after
    /// the row at `startIndex`.
    mutating func replace(with rows: [Row], carryingAdded carriedCount: Int, after startIndex: Int) {
        replace(with: rows)
        if carriedCount > 0 {
            added = AddedRun(start: startIndex + 1, count: carriedCount)
        }
    }

    /// The queue was set again without its first `count` songs (MusicKit only took it from
    /// the song that plays on, #476): every position moves up by `count`, and added songs
    /// before that are gone.
    mutating func dropFirst(_ count: Int) {
        guard count > 0 else { return }
        rows = rows.count > count ? Array(rows.dropFirst(count)) : []
        rowsByEntryID = [:]
        if let run = added {
            let start = max(0, run.start - count)
            let end = run.start + run.count - count
            added = end > start ? AddedRun(start: start, count: end - start) : nil
        }
        generation &+= 1
    }

    /// The book went back to a queue it held before (a refused start gave that queue back): an
    /// add planned before that is ignored, since MusicKit took it into another queue.
    mutating func forgetPendingAdds() {
        generation &+= 1
    }

    /// `count` added songs now sit right after the current song from position `start` (put
    /// there after shuffle reordered a new queue).
    mutating func markAdded(start: Int, count: Int) {
        added = count > 0 ? AddedRun(start: start, count: count) : nil
    }

    /// Shuffle reorders what plays next, so the positions kept so far no longer hold.
    mutating func forgetPositions() {
        rows = []
        added = nil
        generation &+= 1
    }

    /// Where Autoplay puts `row`: at the very end, after everything queued, so the songs the
    /// listener queued keep their places (#613). The added run stays as it is: it sits before
    /// the end. With nothing current it starts a queue, like ``planAdd``.
    func planAppend(_ row: Row, currentIndex: Int?, entryCount: Int) -> AddPlan {
        guard let currentIndex else { return planAdd(row, currentIndex: nil, entryCount: entryCount) }
        let index = max(entryCount, currentIndex + 1)
        return AddPlan(
            index: index,
            isAfterCurrent: index == currentIndex + 1,
            row: row,
            entryCount: entryCount,
            rowsMatchQueue: rows.count == entryCount,
            added: added,
            generation: generation
        )
    }

    /// Where "Add to queue" puts `row`: after the current entry and after the added songs
    /// still ahead of it, so added songs play in the order they were added, before the rest,
    /// like Spotify's queue.
    func planAdd(_ row: Row, currentIndex: Int?, entryCount: Int) -> AddPlan {
        let index: Int?
        let run: AddedRun?
        if let currentIndex {
            if let added, added.start + added.count > currentIndex + 1 {
                index = min(added.start + added.count, entryCount)
                run = AddedRun(start: added.start, count: added.count + 1)
            } else {
                index = currentIndex + 1
                run = AddedRun(start: currentIndex + 1, count: 1)
            }
        } else {
            index = nil
            run = nil
        }
        return AddPlan(
            index: index,
            isAfterCurrent: index == nil || index == currentIndex.map { $0 + 1 },
            row: row,
            entryCount: entryCount,
            rowsMatchQueue: rows.count == entryCount,
            added: run,
            generation: generation
        )
    }

    /// Records an add MusicKit made as planned. Ignored when the queue was replaced or
    /// reordered while the add was waiting for MusicKit.
    mutating func finishAdd(_ plan: AddPlan) {
        guard plan.generation == generation else { return }
        added = plan.added
        guard let index = plan.index else {
            rows = plan.entryCount == 0 ? [plan.row] : []
            return
        }
        if plan.rowsMatchQueue {
            rows.insert(plan.row, at: min(index, rows.count))
        } else {
            rows = []
        }
    }

    /// What the book held for the entries a removal took out, so ``restore(_:)`` puts it back.
    struct Removal: Equatable {
        /// Each removed entry's row, when the book knew it.
        let rows: [Row?]
        /// Which of the removed entries were songs added with Add to Queue.
        let wereAdded: [Bool]
    }

    /// The entries at `indices` (queue positions, any order) were taken out of a queue of
    /// `entryCount` entries (#628). Rows after them move up, and the run of added songs
    /// shrinks by the ones that were in it.
    @discardableResult
    mutating func remove(at indices: [Int], entryCount: Int) -> Removal {
        let sorted = Array(Set(indices)).sorted()
        let rowsMatchQueue = rows.count == entryCount
        let removal = Removal(
            rows: sorted.map { rowsMatchQueue && rows.indices.contains($0) ? rows[$0] : nil },
            wereAdded: sorted.map { index in added.map { $0.start <= index && index < $0.start + $0.count } ?? false }
        )
        for index in sorted.reversed() {
            if rowsMatchQueue, rows.indices.contains(index) { rows.remove(at: index) }
            if var run = added {
                if index < run.start {
                    run.start -= 1
                } else if index < run.start + run.count {
                    run.count -= 1
                }
                added = run.count > 0 ? run : nil
            }
        }
        if !rowsMatchQueue { rows = [] }
        // An add planned before this would land on a stale position.
        generation &+= 1
        return removal
    }

    /// Undo of ``remove(at:entryCount:)``: the entries went back in at `indices` (ascending,
    /// positions after the insert) into a queue that had `entryCount` entries before it.
    mutating func restore(_ removal: Removal, at indices: [Int], entryCount: Int) {
        let rowsMatchQueue = rows.count == entryCount
        for (offset, index) in indices.enumerated() {
            let row = removal.rows.indices.contains(offset) ? removal.rows[offset] : nil
            if rowsMatchQueue, let row, index <= rows.count {
                rows.insert(row, at: index)
            } else {
                rows = []
            }
            let wasAdded = removal.wereAdded.indices.contains(offset) && removal.wereAdded[offset]
            guard var run = added else {
                if wasAdded { added = AddedRun(start: index, count: 1) }
                continue
            }
            if wasAdded, index >= run.start, index <= run.start + run.count {
                // Back next to (or inside) the run it was part of.
                run.count += 1
                run.start = min(run.start, index)
            } else if index <= run.start {
                run.start += 1
            } else if index < run.start + run.count {
                run.count += 1
            }
            added = run
        }
        generation &+= 1
    }

    /// The row of a queue entry: by its id when it was noted, else by its position when the
    /// entry there still shows that row's title.
    func rowURI(entryID: String? = nil, at index: Int?, title: String) -> String? {
        if let entryID, let row = rowsByEntryID[entryID], row.title == title { return row.uri }
        guard let index, rows.indices.contains(index), rows[index].title == title else { return nil }
        return rows[index].uri
    }
}
