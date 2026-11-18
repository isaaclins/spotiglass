import Foundation

/// What a play command starts. Every `uri` is the service's opaque playback
/// reference; only the provider that handed it out interprets it.
enum MusicPlaybackRequest: Equatable {
    /// One track or episode.
    case item(uri: String)
    /// A playlist, album or artist, in the service's own order.
    case context(uri: String)
    /// An explicit list of items, starting at `startURI` (the first item when nil).
    case items(uris: [String], startURI: String?)
}

/// Optional behaviour a playback provider has. The session and the UI ask for
/// these instead of assuming a Spotify-shaped player.
struct MusicPlaybackCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// The in-app player pushes its state as events (Spotify's Web Playback SDK:
    /// `stateChanged`, `playerCommandFinished`). Without it, the in-app player is
    /// handled like a remote one: its state comes only from
    /// ``MusicPlaybackProvider/fetchPlaybackState()``, and play / pause are
    /// confirmed optimistically until a read agrees. Reads may lag a command
    /// (MusicKit's `ApplicationMusicPlayer` still reports "playing" for a moment
    /// after `stop()`), so for a short settle window after a pause, resume or
    /// play the session only applies reads whose play / pause agrees with it.
    /// Polling then also runs while the app is in the background, and an empty
    /// read (`nil`, nothing active) puts the session back to ready.
    static let pushesPlayerState = MusicPlaybackCapabilities(rawValue: 1 << 0)

    /// The in-app player lives in an embedded page that can be soft-reset
    /// (disconnect, then connect) and reloaded when it stops answering
    /// (Spotify's hidden `WKWebView`). Without it, recovery only retries
    /// ``MusicPlaybackProvider/connectPlayer(generation:)``.
    static let reloadablePlayer = MusicPlaybackCapabilities(rawValue: 1 << 1)

    /// The in-app player has its own volume
    /// (``MusicPlaybackProvider/setVolume(_:generation:)``; Spotify: `player.setVolume`).
    /// Without it the volume control is hidden and the Mac's volume applies (MusicKit's
    /// `ApplicationMusicPlayer` has no volume).
    static let playerVolume = MusicPlaybackCapabilities(rawValue: 1 << 2)
}

/// Moving playback between the service's devices (Spotify Connect).
/// Services without other devices return `nil` from
/// ``MusicPlaybackProvider/deviceTransfer``; the UI then hides the device list.
@MainActor
protocol MusicPlaybackDeviceTransfer: AnyObject {
    func fetchAvailableDevices() async throws -> [MusicPlaybackDevice]
    func transferPlayback(to deviceID: String, play: Bool) async throws
}

/// Taking songs out of the queue and putting them back (#628).
@MainActor
protocol MusicQueueEditing: AnyObject {
    /// Takes the songs out of what plays next. Each removal names the song's place in the
    /// upcoming list of the queue the listener saw (`seen`) and its URI: when the queue moved
    /// on meanwhile (a song ended), the places are counted again from what still follows, and
    /// a song that started playing or left the queue is left out.
    func removeFromQueue(_ removals: [QueueRemoval], seen: QueueSnapshot) async throws -> QueueRemovalReceipt
    /// Takes out everything after the current song.
    func clearUpcomingQueue() async throws -> QueueRemovalReceipt
    /// Puts the songs of a removal back where they were, counted from the current song.
    func restoreToQueue(_ receipt: QueueRemovalReceipt) async throws
}

/// One song to take out of the queue: its place in the upcoming list (0 is the song right
/// after the current one) and its URI.
struct QueueRemoval: Equatable, Sendable {
    let position: Int
    let uri: String?
}

/// The queue as the listener saw it: the playing song and what follows, by URI.
struct QueueSnapshot: Equatable, Sendable {
    let current: String?
    let upcoming: [String?]

    /// The playing song (when there is one) followed by the upcoming ones.
    var all: [String?] { (current.map { [$0] } ?? []) + upcoming }
}

/// What a removal took out, so Undo can put it back. `positions` are each song's place in
/// the upcoming list before the removal, in ascending order, one per track.
struct QueueRemovalReceipt: Equatable {
    let id: UUID
    let positions: [Int]
    let tracks: [MusicTrack]

    init(id: UUID = UUID(), positions: [Int], tracks: [MusicTrack]) {
        self.id = id
        self.positions = positions
        self.tracks = tracks
    }

    var count: Int { tracks.count }
}

/// Which upcoming songs a removal takes out, worked out on the queue as it is now.
enum QueueRemovalPlan {
    /// The upcoming positions to remove, ascending.
    ///
    /// When the queue the listener saw (`seen`, playing song included) still lines up with the
    /// queue now after songs ended (all of what's left of it starts the queue now), each place
    /// moves up by the songs that ended, and a song that ended or started playing is left out:
    /// a later copy of the same song is never taken in its stead. Otherwise a removal whose
    /// position still holds its URI takes that position, else the nearest upcoming song with
    /// that URI that isn't taken yet, else nothing (the song played or left the queue meanwhile).
    static func positions(
        for removals: [QueueRemoval],
        upcomingURIs: [String?],
        currentURI: String? = nil,
        seen: QueueSnapshot? = nil
    ) -> [Int] {
        // The playing song is compared only when both sides know it.
        let now = QueueSnapshot(current: seen?.current == nil ? nil : currentURI, upcoming: upcomingURIs)
        let before = seen.map { QueueSnapshot(current: now.current == nil ? nil : $0.current, upcoming: $0.upcoming) }
        if let before, let ended = endedCount(seen: before.all, now: now.all) {
            let shift = ended + (now.current == nil ? 0 : 1) - (before.current == nil ? 0 : 1)
            return Array(Set(removals.compactMap { removal -> Int? in
                let position = removal.position - shift
                guard position >= 0, upcomingURIs.indices.contains(position),
                      same(upcomingURIs[position], removal.uri)
                else { return nil }
                return position
            })).sorted()
        }
        var taken: Set<Int> = []
        for removal in removals.sorted(by: { $0.position < $1.position }) {
            let wanted = MusicPlayableURI.canonical(removal.uri) ?? removal.uri
            func matches(_ index: Int) -> Bool {
                guard upcomingURIs.indices.contains(index), !taken.contains(index) else { return false }
                return (MusicPlayableURI.canonical(upcomingURIs[index]) ?? upcomingURIs[index]) == wanted
            }
            if matches(removal.position) {
                taken.insert(removal.position)
                continue
            }
            let nearest = upcomingURIs.indices
                .filter(matches)
                .min { abs($0 - removal.position) < abs($1 - removal.position) }
            if let nearest { taken.insert(nearest) }
        }
        return taken.sorted()
    }

    /// How many songs at the front of `seen` ended since: the fewest whose removal leaves all
    /// of the rest of `seen` as the start of `now` (songs added at the end since don't
    /// matter). `nil` when none does: the queue changed some other way.
    static func endedCount(seen: [String?], now: [String?]) -> Int? {
        (0..<seen.count).first { ended in
            let rest = seen.dropFirst(ended)
            return rest.count <= now.count && zip(rest, now).allSatisfy { same($0, $1) }
        }
    }

    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        (MusicPlayableURI.canonical(lhs) ?? lhs) == (MusicPlayableURI.canonical(rhs) ?? rhs)
    }
}

/// Everything the playback session sends to, and reads from, a music service's
/// player: starting items or a context, pause / resume, seek, skip, shuffle,
/// repeat, volume, the queue, and the player's state.
///
/// `PlaybackSessionViewModel` and `QueueViewModel` depend on this protocol only.
/// Spotify is the first implementation (``SpotifyPlaybackProvider``: Web API
/// commands plus the Web Playback SDK in a hidden web view).
///
/// **Devices.** Commands name the device that should run them. `deviceID` is
/// opaque: the provider reports the in-app player's id in
/// ``MusicPlaybackEvent/ready(deviceID:)``, and remote ids only come from
/// ``deviceTransfer``. A service with a single local player reports one
/// constant id and may ignore it in commands; it reports the same id again
/// after a reconnect.
///
/// **State.** The provider reports through ``eventHandler`` (ready, errors, and
/// state changes if it has ``MusicPlaybackCapabilities/pushesPlayerState``) and
/// answers ``fetchPlaybackState()`` reads, which the session polls.
///
/// **Lifecycle.** Each connect starts a new ``PlaybackHostGeneration``. Commands
/// that carry one are dropped by the provider once a newer one started, and
/// events carry the generation they belong to.
@MainActor
protocol MusicPlaybackProvider: AnyObject {
    /// The service whose player this is.
    var service: MusicService { get }
    var capabilities: MusicPlaybackCapabilities { get }

    /// True while a play is still handing the player its queue, so a queue read now returns
    /// the queue from before it. The queue panel reads again until it isn't (#413).
    var isQueueSettling: Bool { get }

    /// Spotify Connect style device transfer, or `nil` when the service has none.
    var deviceTransfer: (any MusicPlaybackDeviceTransfer)? { get }

    /// Taking songs out of what plays next, or `nil` when the service can't (#628). Spotify's
    /// Web API has no endpoint that removes a queued song, so Spotify has none.
    var queueEditing: (any MusicQueueEditing)? { get }

    /// Receives every player event. The session installs it when it is created;
    /// the provider calls it on the main actor, synchronously, in event order.
    var eventHandler: ((MusicPlaybackEventEnvelope) -> Void)? { get set }

    // MARK: - Player lifecycle

    /// Prepares the in-app player for a new lifecycle (Spotify: loads the SDK page).
    func loadPlayer(generation: PlaybackHostGeneration)
    /// Connects the in-app player. Success is reported by a `ready` event.
    func connectPlayer(generation: PlaybackHostGeneration) async throws
    func disconnectPlayer(generation: PlaybackHostGeneration) async throws

    // MARK: - Commands for a device

    func play(_ request: MusicPlaybackRequest, deviceID: String) async throws
    func pause(deviceID: String) async throws
    func resume(deviceID: String) async throws
    func seek(to milliseconds: Int, deviceID: String) async throws
    func skipToNext(deviceID: String) async throws
    func skipToPrevious(deviceID: String) async throws
    func setShuffle(enabled: Bool, deviceID: String) async throws
    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws
    func enqueue(uri: String, deviceID: String) async throws
    /// Adds `track` at the very end of the queue, after everything queued (Autoplay, #613).
    /// The default is ``enqueue(uri:deviceID:)``, for a service whose queue has only one place
    /// to add to. `isWanted` is asked right before the queue changes: an add the caller no
    /// longer wants (Autoplay turned off while it waited) leaves the queue alone.
    func appendToQueueEnd(_ track: MusicTrack, deviceID: String, isWanted: @escaping @MainActor () -> Bool) async throws

    // MARK: - Commands for the in-app player

    /// Toggles the in-app player. With ``MusicPlaybackCapabilities/pushesPlayerState``
    /// the provider confirms with a `playerCommandFinished` event.
    func togglePlayPause(commandID: UInt64?) async throws
    /// Pauses (`false`) or plays (`true`) the in-app player. A press that knows the state it
    /// wants sends this rather than a toggle: the player may not have applied the press before
    /// it, and a second toggle then flips the old state (#437).
    /// `commandID` comes back with the player's answer (Spotify: `playerCommandFinished` /
    /// `playerCommandFailed`), so the session knows which press it answers.
    func setInAppPlayerPlaying(_ playing: Bool, commandID: UInt64?) async throws
    /// Sets the in-app player's volume, 0...1.
    func setVolume(_ volume: Double, generation: PlaybackHostGeneration) async throws
    /// Tells the in-app player that the service accepted a play command for `uri`
    /// on it. Spotify notes it in the SDK page's log; most services need nothing.
    func didStartLocalPlayback(uri: String) async throws

    // MARK: - Reads

    /// The active player's state, or `nil` when nothing is active.
    func fetchPlaybackState() async throws -> MusicPlaybackSnapshot?
    /// What plays after the current item.
    func fetchQueue() async throws -> MusicPlaybackQueue
}

extension MusicPlaybackProvider {
    var deviceTransfer: (any MusicPlaybackDeviceTransfer)? { nil }

    var queueEditing: (any MusicQueueEditing)? { nil }

    var isQueueSettling: Bool { false }

    func didStartLocalPlayback(uri: String) async throws {}

    func appendToQueueEnd(_ track: MusicTrack, deviceID: String, isWanted: @escaping @MainActor () -> Bool) async throws {
        guard isWanted() else { throw CancellationError() }
        try await enqueue(uri: track.uri, deviceID: deviceID)
    }
}

/// An add to the end of the queue that was left out on purpose.
enum QueueAppendSkipped: Error, Equatable {
    /// The song was queued meanwhile (added by hand while Autoplay waited its turn), also as
    /// another copy of it, like the library copy of a catalog song.
    case alreadyQueued
}
