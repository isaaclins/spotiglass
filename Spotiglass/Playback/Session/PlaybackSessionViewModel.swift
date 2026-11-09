import AppKit
import Combine
import CoreAudio
import Foundation

protocol PlaybackClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws
}

extension ContinuousClock: PlaybackClock {}

struct PlaybackSeekOwnershipKey: Equatable, Sendable {
    let hostGeneration: PlaybackHostGeneration
    let trackURI: String?
    let trackGeneration: UInt64
}

struct PlaybackSeekIntent: Equatable, Sendable {
    let milliseconds: Int
    let owner: PlaybackSeekOwnershipKey
}

@MainActor
final class PlaybackSessionViewModel: ObservableObject {
    /// Declared here because the session's properties use ``PublishedWhenChanged``, which announces
    /// only real changes (#409).
    let objectWillChange = ObservableObjectPublisher()

    struct PendingVolumeMutation: Equatable, Sendable {
        let target: Double
        let deadline: ContinuousClock.Instant
    }

    /// What the player is doing. An update that only moves the position (every new reading from
    /// the player while a track plays) doesn't publish a change of the session: views that show
    /// the position observe ``progress`` instead, so the rest of the window stays as it is (#409).
    var connectionState: PlaybackConnectionState = .disconnected {
        willSet {
            if newValue.ignoringPosition != connectionState.ignoringPosition {
                objectWillChange.send()
            }
        }
        didSet {
            if connectionState.ignoringPosition != oldValue.ignoringPosition {
                connectionStateSubject.send(connectionState)
            }
        }
    }
    private let connectionStateSubject = CurrentValueSubject<PlaybackConnectionState, Never>(.disconnected)
    /// ``connectionState`` now and after each change, leaving out changes that only move the position.
    var connectionStatePublisher: AnyPublisher<PlaybackConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    /// The moving position, for the progress bar and the lyrics.
    let progress = PlaybackProgressModel()
    /// Display-only playback position anchor for smooth scrubber interpolation. Lives in
    /// ``progress``, so setting it re-renders only the views that observe the position.
    var progressAnchor: PlaybackProgressAnchor? {
        get { progress.anchor }
        set { progress.anchor = newValue }
    }
    /// The device ID owned by the embedded Web Playback SDK.
    @PublishedWhenChanged var deviceID: String?
    /// Another service's library is on screen (#373). What is already playing keeps playing and can
    /// still be paused or skipped, but nothing from that library may start in this player: its
    /// items aren't Spotify's, and Spotify would reject them and show an error after switching back.
    @PublishedWhenChanged var refusesNewPlayback = false
    /// Runs when this player is about to start new music: the other service's player pauses, so
    /// only one library plays at a time (#373).
    var onWillStartPlayback: (() -> Void)?

    /// The other service's player (#396), linked by ``SpotiglassPlaybackHosts`` once both exist.
    weak var otherServicePlayer: PlaybackSessionViewModel?
    /// Whether the other service's player is playing right now, kept by ``SpotiglassPlaybackHosts``.
    @PublishedWhenChanged var isOtherServicePlaying = false
    /// The other service's repeat mode, kept by ``SpotiglassPlaybackHosts``: the Playback menu
    /// shows the repeat of the music you hear.
    @PublishedWhenChanged var otherServiceRepeatMode: MusicRepeatMode = .off
    /// Whether the other service's player takes repeat changes
    /// (``isTransportMutationReady``), kept by ``SpotiglassPlaybackHosts``.
    @PublishedWhenChanged var isOtherServiceTransportMutationReady = false

    /// The other service's player started something: pause what plays here, if anything.
    func pauseForHandover() {
        guard PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState) else { return }
        requestTogglePlayPause()
    }

    /// The player the transport bar, Space, the Playback menu and the palette control (#396):
    /// the one you hear. While the other service's music plays and nothing plays here, that is
    /// the other service's player, so Play/Pause pauses what you hear instead of starting this
    /// service's paused song. Otherwise it is this player.
    var audiblePlayer: PlaybackSessionViewModel {
        guard isOtherServicePlaying,
              !PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState),
              let otherServicePlayer
        else { return self }
        return otherServicePlayer
    }

    /// The service whose player this is.
    var service: MusicService {
        provider.service
    }

    /// A read player (MusicKit) that is only ready, with no play on its way, has nothing
    /// loaded (#396): Play is off, and Add to Queue has no queue to add to. After a sign-out
    /// MusicKit still holds the old queue, so an add would bring the old songs back.
    var hasNothingLoaded: Bool {
        guard !playerPushesState, pendingPlayTransition == nil, case .ready = connectionState else { return false }
        return true
    }
    /// The Spotify Connect device currently targeted by Web API playback commands.
    /// This can be remote while ``deviceID`` remains ready for local SDK events.
    @PublishedWhenChanged private(set) var activePlaybackDeviceID: String?
    /// The device ID to use for a Spotify Web API playback command.
    var commandDeviceID: String? {
        activePlaybackDeviceID ?? deviceID
    }

    func setTransportStateKnown(_ known: Bool) {
        isTransportStateKnown = known
    }

    func setActivePlaybackDeviceID(_ deviceID: String?) {
        activePlaybackDeviceID = deviceID
    }

    /// Whether Spotify playback is currently routed away from the embedded SDK device.
    var isRemotePlaybackActive: Bool {
        guard let activePlaybackDeviceID, let deviceID else { return false }
        return activePlaybackDeviceID != deviceID
    }

    /// Whether the player that plays right now reports its state only when read:
    /// a remote device, or an in-app player that does not push state events
    /// (MusicKit's `ApplicationMusicPlayer`). Such state comes from transport reads,
    /// and play / pause are confirmed optimistically until a read agrees.
    var isPlayerStateRead: Bool {
        isRemotePlaybackActive || !provider.capabilities.contains(.pushesPlayerState)
    }

    /// Whether the service can move playback to another device (Spotify Connect).
    /// The device menu hides its device list when it can't.
    var supportsDeviceTransfer: Bool {
        provider.deviceTransfer != nil
    }

    /// Whether the in-app player has its own volume. The transport bar hides its volume
    /// control when it doesn't (Apple Music: the Mac's volume applies).
    var supportsPlayerVolume: Bool {
        provider.capabilities.contains(.playerVolume)
    }
    /// The Spotify playlist ID that the current playback originated from, or
    /// `nil` if playback was started from a single track URI or external context.
    /// Used by the sidebar to highlight which playlist row is "now playing".
    @PublishedWhenChanged var activePlaylistID: String?
    /// Upcoming tracks from Web Playback SDK `track_window.next_tracks` (immediate UI).
    @PublishedWhenChanged var sdkNextTracks: [PlaybackNowPlaying] = []
    /// Web Playback SDK output gain (`player.setVolume`), 0...1. Persisted between launches.
    @PublishedWhenChanged private(set) var playbackVolume: Double
    /// From `GET /v1/me/player` for the active Spotify player (may be this device or another).
    @PublishedWhenChanged var shuffleEnabled = false
    @PublishedWhenChanged var repeatMode: MusicRepeatMode = .off
    /// True only after a player snapshot has supplied the current shuffle/repeat state.
    /// The values above remain harmless display defaults until this becomes true.
    @PublishedWhenChanged private(set) var isTransportStateKnown = false
    /// Spotify Connect devices from `GET /v1/me/player/devices`.
    @PublishedWhenChanged var connectDevices: [MusicPlaybackDevice] = []
    /// Core Audio output-capable devices (system default output picker).
    @PublishedWhenChanged var macAudioOutputDevices: [MacAudioOutputDevice] = []
    /// Current HAL default output device id (for menu checkmarks).
    @PublishedWhenChanged var systemDefaultOutputDeviceID: AudioDeviceID?
    /// Resolved SF Symbol for the playback-bar device button (hybrid: macOS output when this Web Playback device is active).
    @PublishedWhenChanged var trayOutputSymbolName = "headphones"
    @PublishedWhenChanged var isRefreshingConnectDevices = false

    var diagnostics = PlaybackSessionDiagnostics()

    var playCommandAttemptedCount: Int {
        get { diagnostics.playCommandAttemptedCount }
        set { diagnostics.playCommandAttemptedCount = newValue }
    }
    var playCommandDedupedCount: Int {
        get { diagnostics.playCommandDedupedCount }
        set { diagnostics.playCommandDedupedCount = newValue }
    }
    var playCommandSentCount: Int {
        get { diagnostics.playCommandSentCount }
        set { diagnostics.playCommandSentCount = newValue }
    }
    var playCommandSupersededCount: Int {
        get { diagnostics.playCommandSupersededCount }
        set { diagnostics.playCommandSupersededCount = newValue }
    }
    var nextCommandAttemptedCount: Int {
        get { diagnostics.nextCommandAttemptedCount }
        set { diagnostics.nextCommandAttemptedCount = newValue }
    }
    var nextCommandSentCount: Int {
        get { diagnostics.nextCommandSentCount }
        set { diagnostics.nextCommandSentCount = newValue }
    }
    var nextCommandDroppedDedupeCount: Int {
        get { diagnostics.nextCommandDroppedDedupeCount }
        set { diagnostics.nextCommandDroppedDedupeCount = newValue }
    }
    var nextCommandDroppedLockoutCount: Int {
        get { diagnostics.nextCommandDroppedLockoutCount }
        set { diagnostics.nextCommandDroppedLockoutCount = newValue }
    }
    var nextCommandTimeoutUnlockCount: Int {
        get { diagnostics.nextCommandTimeoutUnlockCount }
        set { diagnostics.nextCommandTimeoutUnlockCount = newValue }
    }
    var playbackHostReloadAttemptCount: Int {
        get { diagnostics.playbackHostReloadAttemptCount }
        set { diagnostics.playbackHostReloadAttemptCount = newValue }
    }
    var playbackHostReloadSuppressedCooldownCount: Int {
        get { diagnostics.playbackHostReloadSuppressedCooldownCount }
        set { diagnostics.playbackHostReloadSuppressedCooldownCount = newValue }
    }
    var playbackHostReloadSuppressedBudgetCount: Int {
        get { diagnostics.playbackHostReloadSuppressedBudgetCount }
        set { diagnostics.playbackHostReloadSuppressedBudgetCount = newValue }
    }
    var playbackHostReuseConnectAttemptCount: Int {
        get { diagnostics.playbackHostReuseConnectAttemptCount }
        set { diagnostics.playbackHostReuseConnectAttemptCount = newValue }
    }
    var playbackHostReuseSoftResetAttemptCount: Int {
        get { diagnostics.playbackHostReuseSoftResetAttemptCount }
        set { diagnostics.playbackHostReuseSoftResetAttemptCount = newValue }
    }
    var playbackHostReuseSuccessCount: Int {
        get { diagnostics.playbackHostReuseSuccessCount }
        set { diagnostics.playbackHostReuseSuccessCount = newValue }
    }
    var playbackHostRecoveryFailureCount: Int {
        get { diagnostics.playbackHostRecoveryFailureCount }
        set { diagnostics.playbackHostRecoveryFailureCount = newValue }
    }
    var playbackHostReloadAttemptsByCause: [String: Int] {
        get { diagnostics.playbackHostReloadAttemptsByCause }
        set { diagnostics.playbackHostReloadAttemptsByCause = newValue }
    }
    var playbackHostReloadSuppressedCooldownByCause: [String: Int] {
        get { diagnostics.playbackHostReloadSuppressedCooldownByCause }
        set { diagnostics.playbackHostReloadSuppressedCooldownByCause = newValue }
    }
    var playbackHostReloadSuppressedBudgetByCause: [String: Int] {
        get { diagnostics.playbackHostReloadSuppressedBudgetByCause }
        set { diagnostics.playbackHostReloadSuppressedBudgetByCause = newValue }
    }
    var playbackHostReuseAttemptsByCause: [String: Int] {
        get { diagnostics.playbackHostReuseAttemptsByCause }
        set { diagnostics.playbackHostReuseAttemptsByCause = newValue }
    }
    var playbackHostRecoveryFailuresByCause: [String: Int] {
        get { diagnostics.playbackHostRecoveryFailuresByCause }
        set { diagnostics.playbackHostRecoveryFailuresByCause = newValue }
    }

    /// The music service's player. Everything the session sends or reads goes through it.
    let provider: any MusicPlaybackProvider
    let macAudioOutput: MacDefaultAudioOutputProviding
    /// Shared EQ route state used to keep system-output selections inside the
    /// equalizer instead of bypassing its virtual device.
    let equalizerEngine: AudioEqualizerEngine?
    /// Backing store for the persisted playback volume. Production uses
    /// `.standard`; tests inject an ephemeral suite so a test run cannot
    /// overwrite the real user's stored volume.
    private let defaults: UserDefaults
    /// Core Audio listener; accessed from `deinit` for removal — must be `nonisolated(unsafe)`.
    nonisolated(unsafe) var hardwareDevicesListener: AudioObjectPropertyListenerBlock?
    var latestPlayerSnapshot: MusicPlaybackSnapshot?
    private var becameActiveObserver: NSObjectProtocol?
    private var resignedActiveObserver: NSObjectProtocol?
    let clock: any PlaybackClock
    let pendingShuffleTimeout: Duration
    let pendingRepeatTimeout: Duration
    let pendingSeekTimeout: Duration
    let repeatWriteMinInterval: Duration
    let postShuffleSyncDelay: Duration
    let postRepeatSyncDelay: Duration
    let seekRateLimitInterval: Duration
    let seekDeduplicationWindowMilliseconds: Int
    let seekMatchToleranceMilliseconds: Int
    let pendingVolumeTimeout: Duration
    let volumeMatchTolerance: Double
    /// Sliding window in which automatic transfers (auto-resume + ensure-before-play) are budgeted.
    /// User-initiated retries and manual Connect picks bypass the count but still respect the 429 cooldown.
    let autoTransferRollingWindow: Duration
    let autoTransferRollingWindowMax: Int
    /// Cooldown applied after a 429 with no `Retry-After`, so the next attempt is paced even when Spotify omits the hint.
    let transferDefaultCooldown: Duration
    var transportPollTask: Task<Void, Never>?
    var shuffleSyncTask: Task<Void, Never>?
    var repeatSyncTask: Task<Void, Never>?
    var transportSyncInFlight = false
    var transportSyncGeneration: PlaybackHostGeneration?
    var transportSyncQueued = false
    var transportSyncSchedulerTask: Task<Void, Never>?
    var transportSyncSchedulerGeneration: PlaybackHostGeneration?
    /// Last non-empty track URI from SDK state; stabilizes poll keys when `uri` flickers nil.
    var stableTransportTrackURI: String?
    var transportTransientErrorCount = 0
    var transportRateLimitedUntil: ContinuousClock.Instant?
    var localMutationSettleTicksRemaining = 0
    /// What the last pause, resume or play asked a player without pushed state
    /// to report: `true` playing, `false` paused, `nil` no such command in the
    /// current settle window. Reads during the window are checked against it.
    var localCommandExpectsPlaying: Bool?
    /// The item a skip just left, on a player without pushed state. MusicKit's player keeps
    /// reporting the old item (at position 0) for up to about 0.3 s after a skip returns, so
    /// during the settle window a read of this item is stale, not a restart. Cleared by the
    /// first read of another item, by the end of the settle window and by a new play.
    var skipLeftItemURI: String?
    /// Serial of the running transport poll loop, and of the loop whose read is
    /// in flight (if any), so a command doesn't cancel the current loop mid-read.
    var transportPollLoopSerial: UInt64 = 0
    var transportPollReadingSerial: UInt64?

    /// How a local command changes play / pause, for ``localCommandExpectsPlaying``.
    enum LocalCommandPlayExpectation {
        /// The command doesn't touch play / pause (skip, seek, shuffle, transfer);
        /// an expectation from an earlier pause or resume stays.
        case unchanged
        case playing
        case paused
    }
    var volumeMutationVersion: UInt64 = 0
    var pendingVolumeMutation: PendingVolumeMutation?
    var playbackVolumeSendTask: Task<Void, Never>?
    var playbackVolumeSendSerial: UInt64 = 0
    /// `NSApp` doesn't exist yet when the app builds its playback host before the first window
    /// (the Apple Music host has no web view to bring AppKit up early); the app's
    /// didBecomeActive notification sets this once it does.
    var isAppActive = NSApp?.isActive ?? false
    var seekDispatchTask: Task<Void, Never>?
    var seekDispatchSerial: UInt64 = 0
    var lastSeekSentInstant: ContinuousClock.Instant?
    var seekOwnershipKey = PlaybackSeekOwnershipKey(
        hostGeneration: .initial,
        trackURI: nil,
        trackGeneration: 0
    )
    var lastSentSeek: PlaybackSeekIntent?
    var failedSeekOwnershipKey: PlaybackSeekOwnershipKey?
    var hasTransferredPlaybackToCurrentDevice = false
    /// Device IDs superseded by a newer Web Playback SDK ready event or a host reload. Late
    /// events from those devices no longer own this playback lifecycle. Explicit disconnect
    /// clears the fence before a deliberately new lifecycle begins.
    var supersededSDKDeviceIDs: Set<String> = []
    /// A not-ready device may reclaim ownership when recovery reuses the same host. A hard
    /// reload clears this allowance so a late event from the old host cannot reclaim it.
    var reclaimableSDKDeviceID: String?
    /// Monotonically identifies the Web Playback host lifecycle currently owned by this session.
    /// Events and asynchronous completions from an older generation cannot publish into this one.
    var playbackHostGeneration = PlaybackHostGeneration.initial
    var playbackHostConnectTask: Task<Void, Never>?
    var playbackHostConnectTimeoutTask: Task<Void, Never>?
    var playbackHostConnectTimeoutSerial: UInt64 = 0
    var playbackHostRecoveryTask: Task<Void, Never>?
    var playbackHostRecoverySerial: UInt64 = 0
    var playbackHostAutoResumeTask: Task<Void, Never>?
    var playbackHostAutoResumeSerial: UInt64 = 0
    /// Set by `start()` and kept pending until the current generation's accepted ready task
    /// finishes its auto-resume attempt. While set, each replacement ready task inherits the
    /// stale-Spotiglass-device auto-resume intent; without it, direct `.handle(.ready)` test paths
    /// (which never go through `start()`) keep their previous behavior and don't fetch Connect devices.
    var autoResumeOnNextReady = false
    /// Timestamps of recent transfer PUTs, pruned to ``autoTransferRollingWindow``. Drives the
    /// rolling-window budget so a degraded auto-resume / ensure path cannot retry-storm Spotify.
    var transferAttemptInstants: [ContinuousClock.Instant] = []
    /// Set when Spotify replies 429 (or a transfer otherwise warrants pacing); transfer attempts
    /// throw `.rateLimited` until this instant elapses. Cleared on `start()` and `disconnect()`.
    var transferRetryCooldownUntil: ContinuousClock.Instant?
    /// Single-flight guard for transfer requests. New callers await this task before issuing their
    /// own `PUT /v1/me/player`, which collapses concurrent play() bursts to one effective transfer.
    var inflightTransferTask: Task<Bool, Error>?
    var inflightTransferGeneration: PlaybackHostGeneration?
    var inflightTransferSerial: UInt64 = 0
    var activeInflightTransferSerial: UInt64?
    /// Expected repeat mode after an optimistic local toggle. While pending,
    /// stale transport reads from Spotify are ignored for a short window so the
    /// button does not snap back.
    var pendingRepeatMode: MusicRepeatMode?
    var pendingRepeatDeadline: ContinuousClock.Instant?
    var confirmedRepeatMode: MusicRepeatMode = .off
    var repeatWriteInFlight = false
    var desiredRepeatMode: MusicRepeatMode?
    var lastRepeatWriteAt: ContinuousClock.Instant?
    var lastRepeatCommandedMode: MusicRepeatMode?
    /// Expected shuffle state after an optimistic local toggle. Stale transport
    /// reads are ignored while this short-lived expectation is pending.
    var pendingShuffleEnabled: Bool?
    var pendingShuffleDeadline: ContinuousClock.Instant?
    var queuedSeek: PlaybackSeekIntent?
    var coalescedSeek: PlaybackSeekIntent?
    var pendingSeek: PlaybackSeekIntent?
    var pendingSeekDeadline: ContinuousClock.Instant?
    var shuffleMutationVersion: UInt64 = 0
    var inFlightShuffleTarget: Bool?
    var queuedShuffleTarget: Bool?
    var lastConfirmedShuffleEnabled: Bool?
    var connectDevicesRefreshTask: Task<[MusicPlaybackDevice], Error>?
    var connectDevicesRefreshGeneration: PlaybackHostGeneration?
    var lastConnectDevicesRefreshAt: ContinuousClock.Instant?
    let connectDevicesFreshnessWindow: Duration
    let playbackHostHardReloadCooldown: Duration
    let playbackHostHardReloadWindow: Duration
    let playbackHostHardReloadWindowMax: Int
    let playbackHostRecoveryConnectTimeout: Duration
    let playbackHostRecoverySoftResetTimeout: Duration
    /// Maximum time the SDK host may remain in `.connecting` before the UI
    /// receives a retryable error instead of an unbounded spinner.
    let playbackHostConnectTimeout: Duration
    var playbackHostHardReloadInstants: [ContinuousClock.Instant] = []

    /// Owns the SDK state-change fence for one accepted play command. The
    /// command ID makes a late completion unable to clear a newer transition;
    /// the context form also remembers the last identity that the superseded
    /// transition owned because Spotify does not tell us a context's first URI.
    struct PendingPlayTransition {
        enum Kind {
            case uri(expectedURI: String)
            case context(staleURIs: Set<String>)
        }

        let ownerID: UInt64?
        let hostGeneration: PlaybackHostGeneration
        let kind: Kind
        let deadline: ContinuousClock.Instant
        var firstContextURI: String?

        var supersededURIs: Set<String> {
            switch kind {
            case let .uri(expectedURI):
                return Set([expectedURI])
            case let .context(staleURIs):
                var identities = staleURIs
                if let firstContextURI {
                    identities.insert(firstContextURI)
                }
                return identities
            }
        }
    }

    var pendingPlayTransition: PendingPlayTransition?
    var pendingPlayTransitionTimeoutTask: Task<Void, Never>?
    var pendingPlayTransitionSerial: UInt64 = 0
    /// Compatibility projection for diagnostics and existing tests. The
    /// transition itself is the only stored play-fence state.
    var pendingPlayURI: String? {
        guard let transition = pendingPlayTransition else { return nil }
        guard case let .uri(expectedURI) = transition.kind else { return nil }
        return expectedURI
    }
    /// Maximum time we'll suppress mismatched events while waiting for the
    /// Spotify SDK to confirm the requested URI. After this window we fall
    /// back to whatever the SDK reports so the UI cannot deadlock on a track
    /// that Spotify ultimately refused to play.
    let pendingPlayURITimeout: Duration = .seconds(6)

    /// True while a `previous`/`next` Web API call is in flight. Drives a UI
    /// disable on the skip buttons and short-circuits subsequent skip presses
    /// so a held hotkey or rage click cannot stack `POST /v1/me/player/previous`
    /// (or `/next`) requests.
    @PublishedWhenChanged var isSkipCommandPending = false
    @PublishedWhenChanged var isNextCommandLockedOut = false
    /// Last time a skip command was dispatched. Combined with
    /// ``skipCommandMinimumSpacing``, this enforces a minimum interval between
    /// successive `previous`/`next` POSTs even when a request returns quickly.
    var lastSkipDispatchInstant: ContinuousClock.Instant?
    /// Minimum spacing between consecutive skip POSTs. Test paths can lower
    /// this so unit tests do not have to sleep the production cooldown.
    let skipCommandMinimumSpacing: Duration
    let skipCommandLockoutTimeout: Duration
    /// One identity owns a skip from dispatch start through REST completion and
    /// the optional post-success timeout. SDK advance observations attach to
    /// this same identity, so an event cannot be lost while the POST is held.
    struct SkipCommandDispatch {
        enum Kind: Equatable {
            case previous
            case next
        }

        let id: UInt64
        let hostGeneration: PlaybackHostGeneration
        let kind: Kind
        let expectedPreviousURI: String?
        let startedAt: ContinuousClock.Instant
        var observedAdvance = false
        var lockoutDeadline: ContinuousClock.Instant?
    }

    var pendingSkipDispatch: SkipCommandDispatch?
    /// A previous request may run while a completed next request is still
    /// waiting for its URI advance. Both records use the same dispatch type so
    /// the next lockout keeps its owner identity instead of being erased by
    /// the previous request.
    var pendingNextSkipLockout: SkipCommandDispatch?
    var skipCommandSequence: UInt64 = 0
    /// Compatibility projection. The dispatch records above are the only
    /// stored skip transition state.
    var pendingSkipDeadline: ContinuousClock.Instant? {
        if let pendingSkipDispatch, pendingSkipDispatch.kind == .next {
            return pendingSkipDispatch.lockoutDeadline
        }
        return pendingNextSkipLockout?.lockoutDeadline
    }
    let playCommandDedupeWindow: Duration
    var inFlightPlayCommandKey: PlayCommandKey?
    var inFlightPlayCommandID: UInt64?
    var lastDispatchedPlayCommandKey: PlayCommandKey?
    var lastDispatchedPlayCommandInstant: ContinuousClock.Instant?
    var playCommandSequence: UInt64 = 0
    var controlCommandsInFlight = 0
    var transportSyncDeferredWhileControlCommandInFlight = false
    var transportSyncDeferredGeneration: PlaybackHostGeneration?
    var deferredTransportSyncTask: Task<Void, Never>?

    /// True when the Web Playback path is far enough along for transport actions (mirrors transport button enablement).
    var isPlaybackTransportReady: Bool {
        Self.isPlaybackTransportReady(for: connectionState)
    }

    static func isPlaybackTransportReady(for state: PlaybackConnectionState) -> Bool {
        switch state {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
        }
    }

    /// Whether the Play/Pause transport control has a usable target. Local
    /// playback uses the Web Playback SDK; a remote Connect device uses the
    /// Spotify Web API.
    var isPlaybackToggleReady: Bool {
        guard commandDeviceID != nil else { return false }
        return Self.isPlaybackToggleReady(
            connectionState: connectionState,
            deviceID: deviceID,
            activePlaybackDeviceID: activePlaybackDeviceID,
            playerPushesState: playerPushesState
        )
    }

    /// Whether the in-app player pushes its state (Spotify's Web Playback SDK) rather than being
    /// read (MusicKit).
    var playerPushesState: Bool {
        provider.capabilities.contains(.pushesPlayerState)
    }

    static func isPlaybackToggleReady(
        connectionState: PlaybackConnectionState,
        deviceID: String?,
        activePlaybackDeviceID: String?,
        playerPushesState: Bool = true
    ) -> Bool {
        guard Self.isPlaybackTransportReady(for: connectionState) else { return false }
        // A read player that is only ready has nothing loaded (an empty read puts it back to
        // ready): MusicKit's player has no "last played" to resume, so Play would only fail
        // (#396). Choosing a track is the way to start; Spotify resumes the account's last item.
        if !playerPushesState, case .ready = connectionState {
            return false
        }
        // Both the SDK device and a remote Connect device are valid targets;
        // commandDeviceID selects which path the action takes.
        return deviceID != nil || activePlaybackDeviceID != nil
    }

    /// Whether shuffle/repeat commands have both a ready target and a confirmed
    /// Spotify transport state. The visible values are not actionable otherwise.
    var isTransportMutationReady: Bool {
        isTransportStateKnown && isPlaybackTransportReady && commandDeviceID != nil
    }

    /// ``isTransportMutationReady`` from published values, for sinks that run before the
    /// properties change.
    static func isTransportMutationReady(
        isTransportStateKnown: Bool,
        connectionState: PlaybackConnectionState,
        commandDeviceID: String?
    ) -> Bool {
        isTransportStateKnown && isPlaybackTransportReady(for: connectionState) && commandDeviceID != nil
    }

    enum PlaybackHostRecoveryCause: String {
        case startupTask = "view_startup"
        case manualReconnect = "manual_reconnect"
        case initializationError = "initialization_error"
        case notReady = "not_ready"
        case missingDeviceRetryTransfer = "missing_device_retry_transfer"
    }

    /// Play / pause presses in order: each command waits for the one before it (#437).
    var playPauseCommandTail: Task<Void, Never>?
    /// Bumped by every play / pause press; only the latest press's refusal changes the screen.
    var playPauseRequestSerial: UInt64 = 0
    /// What the last press asked Spotify's page to report (`true` playing), until a report
    /// agrees or ``pushedPlayStateExpectationTimeout`` passes. Reports that disagree are older
    /// than the press and are not shown.
    var pushedPlayStateExpectation: Bool?
    var pushedPlayStateExpectationTask: Task<Void, Never>?
    static let pushedPlayStateExpectationTimeout: Duration = .seconds(3)
    /// A play / pause the player refused, shown in the bar for a moment while the controls show
    /// the state from before the press again (#437).
    @PublishedWhenChanged var refusedPlayPause: PlaybackDisplayError?
    var refusedPlayPauseClearTask: Task<Void, Never>?
    static let refusedPlayPauseDisplayDuration: Duration = .seconds(5)

    private static let playbackVolumeUserDefaultsKey = "spotiglass.playbackVolume"
    /// Matches the default passed to `Spotify.Player({ volume: … })` in the embedded host HTML.
    static let defaultPlaybackVolume: Double = 0.8

    struct PlayCommandDispatch {
        let id: UInt64
        let key: PlayCommandKey
    }

    enum PlayCommandKey: Equatable {
        case singleURI(deviceID: String, uri: String)
        case contextURI(deviceID: String, contextURI: String)
        case uriQueue(deviceID: String, headURI: String, queueCount: Int)
    }

    /// Why a transfer is being requested. Drives idempotency, budget, and cooldown gating in the transfer funnel so
    /// user-initiated commands stay responsive while automatic paths cannot retry-storm Spotify.
    enum TransferOrigin {
        case ensureBeforePlay
        case autoResume
        case userRetry
        case userManualConnect

        var isAutomatic: Bool {
            switch self {
            case .ensureBeforePlay, .autoResume: true
            case .userRetry, .userManualConnect: false
            }
        }
    }

    init(
        provider: any MusicPlaybackProvider,
        macAudioOutput: MacDefaultAudioOutputProviding = MacDefaultAudioOutputNameProvider(),
        equalizerEngine: AudioEqualizerEngine? = nil,
        defaults: UserDefaults = .standard,
        clock: any PlaybackClock = ContinuousClock(),
        pendingShuffleTimeout: Duration = .seconds(2),
        pendingRepeatTimeout: Duration = .seconds(2),
        pendingSeekTimeout: Duration = .seconds(2),
        repeatWriteMinInterval: Duration = .milliseconds(300),
        postShuffleSyncDelay: Duration = .milliseconds(350),
        postRepeatSyncDelay: Duration = .milliseconds(350),
        seekRateLimitInterval: Duration = .milliseconds(500),
        seekDeduplicationWindowMilliseconds: Int = 250,
        seekMatchToleranceMilliseconds: Int = 1_250,
        playCommandDedupeWindow: Duration = .milliseconds(400),
        connectDevicesFreshnessWindow: Duration = .seconds(3),
        skipCommandMinimumSpacing: Duration = .milliseconds(350),
        skipCommandLockoutTimeout: Duration = .seconds(2),
        autoTransferRollingWindow: Duration = .seconds(60),
        autoTransferRollingWindowMax: Int = 8,
        transferDefaultCooldown: Duration = .seconds(8),
        playbackHostHardReloadCooldown: Duration = .seconds(30),
        playbackHostHardReloadWindow: Duration = .seconds(300),
        playbackHostHardReloadWindowMax: Int = 2,
        playbackHostRecoveryConnectTimeout: Duration = .seconds(1),
        playbackHostRecoverySoftResetTimeout: Duration = .seconds(2),
        playbackHostConnectTimeout: Duration = .seconds(15),
        pendingVolumeTimeout: Duration = .seconds(3),
        volumeMatchTolerance: Double = 0.01
    ) {
        self.provider = provider
        self.macAudioOutput = macAudioOutput
        self.equalizerEngine = equalizerEngine
        self.defaults = defaults
        self.clock = clock
        self.pendingShuffleTimeout = pendingShuffleTimeout
        self.pendingRepeatTimeout = pendingRepeatTimeout
        self.pendingSeekTimeout = pendingSeekTimeout
        self.repeatWriteMinInterval = repeatWriteMinInterval
        self.postShuffleSyncDelay = postShuffleSyncDelay
        self.postRepeatSyncDelay = postRepeatSyncDelay
        self.seekRateLimitInterval = seekRateLimitInterval
        self.seekDeduplicationWindowMilliseconds = seekDeduplicationWindowMilliseconds
        self.seekMatchToleranceMilliseconds = seekMatchToleranceMilliseconds
        self.pendingVolumeTimeout = pendingVolumeTimeout
        self.volumeMatchTolerance = volumeMatchTolerance
        self.playCommandDedupeWindow = playCommandDedupeWindow
        self.connectDevicesFreshnessWindow = connectDevicesFreshnessWindow
        self.skipCommandMinimumSpacing = skipCommandMinimumSpacing
        self.skipCommandLockoutTimeout = skipCommandLockoutTimeout
        self.autoTransferRollingWindow = autoTransferRollingWindow
        self.autoTransferRollingWindowMax = autoTransferRollingWindowMax
        self.transferDefaultCooldown = transferDefaultCooldown
        self.playbackHostHardReloadCooldown = playbackHostHardReloadCooldown
        self.playbackHostHardReloadWindow = playbackHostHardReloadWindow
        self.playbackHostHardReloadWindowMax = playbackHostHardReloadWindowMax
        self.playbackHostRecoveryConnectTimeout = playbackHostRecoveryConnectTimeout
        self.playbackHostRecoverySoftResetTimeout = playbackHostRecoverySoftResetTimeout
        self.playbackHostConnectTimeout = playbackHostConnectTimeout
        self.playbackVolume = Self.loadStoredPlaybackVolume(from: defaults)

        provider.eventHandler = { [weak self] envelope in
            self?.handle(envelope)
        }

        macAudioOutput.startListening { [weak self] in
            Task { @MainActor in
                self?.handleMacAudioOutputChange()
            }
        }
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isAppActive = true
                await self.syncTransportFromSpotify()
                await self.refreshConnectDevices()
                self.refreshMacAudioOutputDevices()
                self.restartTransportPollingIfNeeded()
            }
        }
        resignedActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isAppActive = false
                self.restartTransportPollingIfNeeded()
            }
        }
        installAudioHardwareDevicesListener()
        refreshMacAudioOutputDevices()
        restartTransportPollingIfNeeded()
    }

    /// Writes only a changed volume. Every write to the defaults, even of the same value, re-renders
    /// each view that uses `@AppStorage`, the whole window included, and the player reports its
    /// volume with every reading (#409).
    private func storePlaybackVolume(_ volume: Double) {
        guard (defaults.object(forKey: Self.playbackVolumeUserDefaultsKey) as? NSNumber)?.doubleValue != volume else { return }
        defaults.set(volume, forKey: Self.playbackVolumeUserDefaultsKey)
    }

    private static func loadStoredPlaybackVolume(from defaults: UserDefaults) -> Double {
        guard let object = defaults.object(forKey: playbackVolumeUserDefaultsKey) else {
            return defaultPlaybackVolume
        }
        if let d = object as? Double {
            return min(max(d, 0), 1)
        }
        if let n = object as? NSNumber {
            return min(max(n.doubleValue, 0), 1)
        }
        return defaultPlaybackVolume
    }

    func setPlaybackVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        let version = beginPendingPlaybackVolumeMutation(target: clamped)
        playbackVolume = clamped
        storePlaybackVolume(clamped)
        schedulePlaybackVolumeSend(
            value: clamped,
            version: version,
            generation: playbackHostGeneration
        )
    }

    @discardableResult
    func beginPendingPlaybackVolumeMutation(target: Double) -> UInt64 {
        let clamped = min(max(target, 0), 1)
        volumeMutationVersion &+= 1
        pendingVolumeMutation = PendingVolumeMutation(
            target: clamped,
            deadline: clock.now.advanced(by: pendingVolumeTimeout)
        )
        return volumeMutationVersion
    }

    func cancelPlaybackVolumeSend() {
        playbackVolumeSendTask?.cancel()
        playbackVolumeSendTask = nil
        playbackVolumeSendSerial &+= 1
    }

    private func schedulePlaybackVolumeSend(
        value: Double,
        version: UInt64,
        generation: PlaybackHostGeneration
    ) {
        cancelPlaybackVolumeSend()
        let serial = playbackVolumeSendSerial
        playbackVolumeSendTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.playbackVolumeSendSerial == serial {
                    self.playbackVolumeSendTask = nil
                }
            }
            guard let self,
                  self.ownsPlaybackHostGeneration(generation),
                  self.volumeMutationVersion == version,
                  self.playbackVolumeSendSerial == serial,
                  !Task.isCancelled else { return }
            try? await self.provider.setVolume(value, generation: generation)
        }
    }

    func applyRemotePlaybackVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        playbackVolume = clamped
        storePlaybackVolume(clamped)
    }

    deinit {
        playbackHostConnectTask?.cancel()
        playbackHostConnectTimeoutTask?.cancel()
        playbackHostRecoveryTask?.cancel()
        playbackHostAutoResumeTask?.cancel()
        connectDevicesRefreshTask?.cancel()
        inflightTransferTask?.cancel()
        pushedPlayStateExpectationTask?.cancel()
        refusedPlayPauseClearTask?.cancel()
        playPauseCommandTail?.cancel()
        transportPollTask?.cancel()
        shuffleSyncTask?.cancel()
        repeatSyncTask?.cancel()
        seekDispatchTask?.cancel()
        playbackVolumeSendTask?.cancel()
        pendingPlayTransitionTimeoutTask?.cancel()
        deferredTransportSyncTask?.cancel()
        transportSyncSchedulerTask?.cancel()
        macAudioOutput.stopListening()
        removeAudioHardwareDevicesListenerForTeardown()
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
        if let resignedActiveObserver {
            NotificationCenter.default.removeObserver(resignedActiveObserver)
        }
    }

    static func playbackDeviceNotReadyError() -> PlaybackDisplayError {
        PlaybackDisplayError(
            title: SpotiglassL10n.string("error.playback.deviceUnavailable.title"),
            message: SpotiglassL10n.string("error.playback.deviceUnavailable.notReady"),
            recoveryAction: .reconnect
        )
    }

    static func playbackDeviceReconnectRequiredError() -> PlaybackDisplayError {
        PlaybackDisplayError(
            title: SpotiglassL10n.string("error.playback.deviceUnavailable.title"),
            message: SpotiglassL10n.string("error.playback.deviceUnavailable.reconnect"),
            recoveryAction: .reconnect
        )
    }

    static func playbackHostConnectionTimedOutError() -> PlaybackDisplayError {
        PlaybackDisplayError(
            title: SpotiglassL10n.string("error.playback.connectionTimeout.title"),
            message: SpotiglassL10n.string("error.playback.connectionTimeout.message"),
            recoveryAction: .reconnect
        )
    }

    static func playbackHostConnectionFailedError(for error: Error) -> PlaybackDisplayError {
        // Apple Music's player is this Mac: its errors say what to do (turn access back on)
        // in the app's language. Spotify keeps this text.
        if let playbackError = error as? MusicPlaybackError, playbackError.service == .appleMusic {
            return displayError(for: playbackError)
        }
        return PlaybackDisplayError(
            title: SpotiglassL10n.string("error.playback.couldNotStart.title"),
            message: String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), error.localizedDescription),
            recoveryAction: .reconnect
        )
    }

    static func displayError(for error: Error) -> PlaybackDisplayError {
        guard let playbackError = MusicPlaybackError.from(error) else {
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                message: String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), error.localizedDescription),
                recoveryAction: .retryTransfer
            )
        }
        switch playbackError.service {
        case .spotify:
            return spotifyDisplayError(for: playbackError)
        case .appleMusic:
            return appleMusicDisplayError(for: playbackError)
        }
    }

    private static func spotifyDisplayError(for error: MusicPlaybackError) -> PlaybackDisplayError {
        switch error.reason {
        case .signInExpired:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.signInAgain.title"),
                message: SpotiglassL10n.string("error.playback.signInAgain.message"),
                recoveryAction: .reauthenticate
            )
        case .missingPermission:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                message: SpotiglassL10n.string("error.spotify.insufficientPermissions"),
                recoveryAction: .reauthenticate
            )
        case let .subscriptionRequired(message):
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.premium.title"),
                message: message ?? SpotiglassL10n.string("error.playback.premium.message"),
                recoveryAction: nil
            )
        case let .rateLimited(retryAfter):
            let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.rateLimited.title"),
                message: String(format: SpotiglassL10n.string("error.playback.rateLimited.message"), clause),
                recoveryAction: .retryTransfer
            )
        case .network, .server, .notFound, .explicitContentRestricted, .failed:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                message: String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), error.detail),
                recoveryAction: .retryTransfer
            )
        }
    }

    /// Apple Music has no sign-in this app can repeat and no transfer to retry: access is a
    /// system permission and the player is this Mac, so its errors say what to do instead.
    private static func appleMusicDisplayError(for error: MusicPlaybackError) -> PlaybackDisplayError {
        switch error.reason {
        case .signInExpired, .missingPermission:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.appleMusic.permission.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.permission.message"),
                recoveryAction: nil
            )
        case .subscriptionRequired:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.appleMusic.subscription.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.subscription.message"),
                recoveryAction: nil
            )
        case .notFound:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.notPlayable"),
                recoveryAction: nil
            )
        case .explicitContentRestricted:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.appleMusic.explicit.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.explicit.message"),
                recoveryAction: nil
            )
        case .rateLimited, .network, .server, .failed:
            return PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.failed"),
                recoveryAction: .reconnect
            )
        }
    }

    func fallbackNowPlaying() -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: PlaybackControlsView.serviceString("playback.fallbackName", appleMusic: "playback.fallbackName.appleMusic"),
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 0,
            positionMilliseconds: 0,
            uri: nil
        )
    }

    var currentNowPlayingURI: String? {
        switch connectionState {
        case let .playing(nowPlaying):
            return nowPlaying.uri
        case let .paused(nowPlaying):
            return nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    var currentNowPlaying: PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(nowPlaying):
            return nowPlaying
        case let .paused(nowPlaying):
            return nowPlaying
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    var currentLyricTrack: PlaybackNowPlaying? {
        connectionState.currentLyricTrack
    }

    func setConnectionState(_ state: PlaybackConnectionState) {
        updateSeekOwnership(from: state)
        updateStableTransportTrackURI(from: state)
        let wasPolling = shouldRunTransportPolling(for: connectionState)
        connectionState = state
        syncProgressAnchorWithConnectionState()
        if shouldRunTransportPolling(for: nil) != wasPolling {
            restartTransportPollingIfNeeded()
        }
    }

    func updateStableTransportTrackURI(from state: PlaybackConnectionState) {
        let uri: String? = switch state {
        case let .playing(nowPlaying):
            nowPlaying.uri
        case let .paused(nowPlaying):
            nowPlaying?.uri
        default:
            nil
        }
        if let uri, !uri.isEmpty {
            stableTransportTrackURI = uri
        }
    }
}
