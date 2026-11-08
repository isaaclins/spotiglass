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
    var capabilities: MusicPlaybackCapabilities { get }

    /// True while a play is still handing the player its queue, so a queue read now returns
    /// the queue from before it. The queue panel reads again until it isn't (#413).
    var isQueueSettling: Bool { get }

    /// Spotify Connect style device transfer, or `nil` when the service has none.
    var deviceTransfer: (any MusicPlaybackDeviceTransfer)? { get }

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

    // MARK: - Commands for the in-app player

    /// Toggles the in-app player. With ``MusicPlaybackCapabilities/pushesPlayerState``
    /// the provider confirms with a `playerCommandFinished` event.
    func togglePlayPause() async throws
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

    var isQueueSettling: Bool { false }

    func didStartLocalPlayback(uri: String) async throws {}
}
