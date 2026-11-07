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
    /// Stops playback and empties the queue: the session is over (signing out of Apple Music),
    /// and adding Apple Music again starts with nothing loaded.
    func endSession()
    func seek(toMilliseconds milliseconds: Int)
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setShuffle(_ enabled: Bool)
    func setRepeat(_ mode: MusicRepeatMode)
    /// Adds an item after the current one and after the items added before it, like
    /// Spotify's "Add to queue".
    func enqueue(uri: String) async throws
    func readState() -> AppleMusicPlayerState
    /// The entries after the current one, in play order.
    func readUpcoming() -> [MusicTrack]
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

    init(player: (any AppleMusicPlayerControlling)? = nil) {
        self.player = player ?? MusicKitApplicationPlayer()
    }

    // MARK: - Player lifecycle

    func loadPlayer(generation: PlaybackHostGeneration) {}

    func connectPlayer(generation: PlaybackHostGeneration) async throws {
        guard player.isAuthorized() else {
            throw MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: "Apple Music access is off")
        }
        eventHandler?(MusicPlaybackEventEnvelope(event: .ready(deviceID: Self.deviceID), hostGeneration: generation))
    }

    /// Disconnecting ends the session (signing out of Apple Music, #396): the music stops and
    /// the queue goes, so nothing keeps playing that the window can't control, and adding Apple
    /// Music again starts fresh instead of showing the old song.
    func disconnectPlayer(generation: PlaybackHostGeneration) async throws {
        player.endSession()
    }

    // MARK: - Commands for a device

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws {
        playGeneration &+= 1
        let generation = playGeneration
        let queueRequest = try Self.queueRequest(for: request)
        let run = Task { @MainActor [player] in
            try await player.play(queueRequest, isCurrent: { [weak self] in self?.playGeneration == generation })
        }
        latestPlay = Task { _ = await run.result }
        try await perform { try await run.value }
    }

    func pause(deviceID: String) async throws {
        player.pause()
    }

    func resume(deviceID: String) async throws {
        try await perform { try await player.resume() }
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
        let previous = enqueueTail
        let pendingPlay = latestPlay
        let add = Task { @MainActor [player] in
            await pendingPlay?.value
            await previous?.value
            try await player.enqueue(uri: uri)
        }
        enqueueTail = Task { _ = await add.result }
        try await perform { try await add.value }
    }

    // MARK: - Commands for the in-app player

    /// The session uses explicit pause / resume for a player without pushed state; this is
    /// only reached by callers that toggle directly.
    func togglePlayPause() async throws {
        if player.readState().status == .playing {
            player.pause()
        } else {
            try await perform { try await player.resume() }
        }
    }

    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws {}

    // MARK: - Reads

    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot? {
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

    func fetchQueue() async throws -> MusicPlaybackQueue {
        MusicPlaybackQueue(queue: player.readUpcoming().map { .track($0) })
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
        } catch {
            throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: String(describing: error))
        }
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

    /// The row of a queue entry: by its id when it was noted, else by its position when the
    /// entry there still shows that row's title.
    func rowURI(entryID: String? = nil, at index: Int?, title: String) -> String? {
        if let entryID, let row = rowsByEntryID[entryID], row.title == title { return row.uri }
        guard let index, rows.indices.contains(index), rows[index].title == title else { return nil }
        return rows[index].uri
    }
}
