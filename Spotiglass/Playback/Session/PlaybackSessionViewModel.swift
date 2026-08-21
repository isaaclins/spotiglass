import AppKit
import CoreAudio
import Foundation

@MainActor
final class PlaybackSessionViewModel: ObservableObject {
    @Published var connectionState: PlaybackConnectionState = .disconnected
    /// Display-only playback position anchor for smooth scrubber interpolation.
    @Published var progressAnchor: PlaybackProgressAnchor?
    /// The device ID owned by the embedded Web Playback SDK.
    @Published var deviceID: String?
    /// The Spotify Connect device currently targeted by Web API playback commands.
    /// This can be remote while ``deviceID`` remains ready for local SDK events.
    @Published private(set) var activePlaybackDeviceID: String?
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
    /// The Spotify playlist ID that the current playback originated from, or
    /// `nil` if playback was started from a single track URI or external context.
    /// Used by the sidebar to highlight which playlist row is "now playing".
    @Published var activePlaylistID: String?
    /// Upcoming tracks from Web Playback SDK `track_window.next_tracks` (immediate UI).
    @Published var sdkNextTracks: [PlaybackNowPlaying] = []
    /// Web Playback SDK output gain (`player.setVolume`), 0...1. Persisted between launches.
    @Published private(set) var playbackVolume: Double
    /// From `GET /v1/me/player` for the active Spotify player (may be this device or another).
    @Published var shuffleEnabled = false
    @Published var repeatMode: SpotifyRepeatMode = .off
    /// True only after a player snapshot has supplied the current shuffle/repeat state.
    /// The values above remain harmless display defaults until this becomes true.
    @Published private(set) var isTransportStateKnown = false
    /// Spotify Connect devices from `GET /v1/me/player/devices`.
    @Published var connectDevices: [SpotifyConnectDevice] = []
    /// Core Audio output-capable devices (system default output picker).
    @Published var macAudioOutputDevices: [MacAudioOutputDevice] = []
    /// Current HAL default output device id (for menu checkmarks).
    @Published var systemDefaultOutputDeviceID: AudioDeviceID?
    /// Resolved SF Symbol for the playback-bar device button (hybrid: macOS output when this Web Playback device is active).
    @Published var trayOutputSymbolName = "headphones"
    @Published var isRefreshingConnectDevices = false

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

    let playbackAPI: SpotifyPlaybackControlling
    let webCommander: WebPlaybackCommanding
    let macAudioOutput: MacDefaultAudioOutputProviding
    /// Backing store for the persisted playback volume. Production uses
    /// `.standard`; tests inject an ephemeral suite so a test run cannot
    /// overwrite the real user's stored volume.
    private let defaults: UserDefaults
    /// Core Audio listener; accessed from `deinit` for removal — must be `nonisolated(unsafe)`.
    nonisolated(unsafe) var hardwareDevicesListener: AudioObjectPropertyListenerBlock?
    var latestPlayerSnapshot: SpotifyPlayerSnapshot?
    private var becameActiveObserver: NSObjectProtocol?
    private var resignedActiveObserver: NSObjectProtocol?
    let clock = ContinuousClock()
    let pendingShuffleTimeout: Duration
    let pendingRepeatTimeout: Duration
    let pendingSeekTimeout: Duration
    let repeatWriteMinInterval: Duration
    let postShuffleSyncDelay: Duration
    let postRepeatSyncDelay: Duration
    let seekRateLimitInterval: Duration
    let seekDeduplicationWindowMilliseconds: Int
    let seekMatchToleranceMilliseconds: Int
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
    var isAppActive = NSApp.isActive
    var seekDispatchTask: Task<Void, Never>?
    var lastSeekSentInstant: ContinuousClock.Instant?
    var lastSentSeekPositionMilliseconds: Int?
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
    var pendingRepeatMode: SpotifyRepeatMode?
    var pendingRepeatDeadline: ContinuousClock.Instant?
    var confirmedRepeatMode: SpotifyRepeatMode = .off
    var repeatWriteInFlight = false
    var desiredRepeatMode: SpotifyRepeatMode?
    var lastRepeatWriteAt: ContinuousClock.Instant?
    var lastRepeatCommandedMode: SpotifyRepeatMode?
    /// Expected shuffle state after an optimistic local toggle. Stale transport
    /// reads are ignored while this short-lived expectation is pending.
    var pendingShuffleEnabled: Bool?
    var pendingShuffleDeadline: ContinuousClock.Instant?
    var queuedSeekPositionMilliseconds: Int?
    var coalescedSeekPositionMilliseconds: Int?
    var pendingSeekDisplayPositionMilliseconds: Int?
    var pendingSeekDeadline: ContinuousClock.Instant?
    var shuffleMutationVersion: UInt64 = 0
    var inFlightShuffleTarget: Bool?
    var queuedShuffleTarget: Bool?
    var lastConfirmedShuffleEnabled: Bool?
    var connectDevicesRefreshTask: Task<[SpotifyConnectDevice], Error>?
    var connectDevicesRefreshGeneration: PlaybackHostGeneration?
    var lastConnectDevicesRefreshAt: ContinuousClock.Instant?
    let connectDevicesFreshnessWindow: Duration
    let playbackHostHardReloadCooldown: Duration
    let playbackHostHardReloadWindow: Duration
    let playbackHostHardReloadWindowMax: Int
    let playbackHostRecoveryConnectTimeout: Duration
    let playbackHostRecoverySoftResetTimeout: Duration
    var playbackHostHardReloadInstants: [ContinuousClock.Instant] = []

    /// URI the user most recently asked to play. While set, any incoming
    /// Web Playback SDK `state_changed` event whose track URI does not match
    /// this URI is ignored as stale. The Spotify SDK can briefly emit a final
    /// event for the previous track during a transition, which would otherwise
    /// cause the now-playing display to flash back to the old song name.
    var pendingPlayURI: String?
    var pendingPlayURIDeadline: ContinuousClock.Instant?
    /// Maximum time we'll suppress mismatched events while waiting for the
    /// Spotify SDK to confirm the requested URI. After this window we fall
    /// back to whatever the SDK reports so the UI cannot deadlock on a track
    /// that Spotify ultimately refused to play.
    let pendingPlayURITimeout: Duration = .seconds(6)

    /// True while a `previous`/`next` Web API call is in flight. Drives a UI
    /// disable on the skip buttons and short-circuits subsequent skip presses
    /// so a held hotkey or rage click cannot stack `POST /v1/me/player/previous`
    /// (or `/next`) requests.
    @Published var isSkipCommandPending = false
    @Published var isNextCommandLockedOut = false
    /// Last time a skip command was dispatched. Combined with
    /// ``skipCommandMinimumSpacing``, this enforces a minimum interval between
    /// successive `previous`/`next` POSTs even when a request returns quickly.
    var lastSkipDispatchInstant: ContinuousClock.Instant?
    /// Minimum spacing between consecutive skip POSTs. Test paths can lower
    /// this so unit tests do not have to sleep the production cooldown.
    let skipCommandMinimumSpacing: Duration
    let skipCommandLockoutTimeout: Duration
    var pendingSkipExpectedPreviousURI: String?
    var pendingSkipDeadline: ContinuousClock.Instant?
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
        switch connectionState {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
        }
    }

    /// Whether shuffle/repeat commands have both a ready target and a confirmed
    /// Spotify transport state. The visible values are not actionable otherwise.
    var isTransportMutationReady: Bool {
        isTransportStateKnown && isPlaybackTransportReady && commandDeviceID != nil
    }

    enum PlaybackHostRecoveryCause: String {
        case startupTask = "view_startup"
        case manualReconnect = "manual_reconnect"
        case initializationError = "initialization_error"
        case notReady = "not_ready"
        case missingDeviceRetryTransfer = "missing_device_retry_transfer"
    }

    /// True while a toggle command is in flight until the bridge ACK or timeout (avoids overlapping SDK toggles).
    var togglePlayPauseAwaitingBridgeAck = false
    var togglePlayPauseAckTimeoutTask: Task<Void, Never>?
    static let togglePlayPauseAckTimeout: Duration = .seconds(3)

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
        playbackAPI: SpotifyPlaybackControlling,
        webCommander: WebPlaybackCommanding,
        macAudioOutput: MacDefaultAudioOutputProviding = MacDefaultAudioOutputNameProvider(),
        defaults: UserDefaults = .standard,
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
        playbackHostRecoverySoftResetTimeout: Duration = .seconds(2)
    ) {
        self.playbackAPI = playbackAPI
        self.webCommander = webCommander
        self.macAudioOutput = macAudioOutput
        self.defaults = defaults
        self.pendingShuffleTimeout = pendingShuffleTimeout
        self.pendingRepeatTimeout = pendingRepeatTimeout
        self.pendingSeekTimeout = pendingSeekTimeout
        self.repeatWriteMinInterval = repeatWriteMinInterval
        self.postShuffleSyncDelay = postShuffleSyncDelay
        self.postRepeatSyncDelay = postRepeatSyncDelay
        self.seekRateLimitInterval = seekRateLimitInterval
        self.seekDeduplicationWindowMilliseconds = seekDeduplicationWindowMilliseconds
        self.seekMatchToleranceMilliseconds = seekMatchToleranceMilliseconds
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
        self.playbackVolume = Self.loadStoredPlaybackVolume(from: defaults)

        macAudioOutput.startListening { [weak self] in
            Task { @MainActor in
                self?.refreshTrayOutputSymbol()
                self?.refreshMacAudioOutputDevices()
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
        playbackVolume = clamped
        defaults.set(clamped, forKey: Self.playbackVolumeUserDefaultsKey)
        Task {
            try? await webCommander.send(.setVolume, payload: ["volume": clamped])
        }
    }

    deinit {
        playbackHostConnectTask?.cancel()
        playbackHostRecoveryTask?.cancel()
        playbackHostAutoResumeTask?.cancel()
        connectDevicesRefreshTask?.cancel()
        inflightTransferTask?.cancel()
        togglePlayPauseAckTimeoutTask?.cancel()
        transportPollTask?.cancel()
        shuffleSyncTask?.cancel()
        repeatSyncTask?.cancel()
        seekDispatchTask?.cancel()
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

    static func displayError(for error: Error) -> PlaybackDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return PlaybackDisplayError(
                    title: SpotiglassL10n.string("error.playback.signInAgain.title"),
                    message: SpotiglassL10n.string("error.playback.signInAgain.message"),
                    recoveryAction: .reauthenticate
                )
            case let .forbidden(message, _):
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
            default:
                return PlaybackDisplayError(
                    title: SpotiglassL10n.string("error.playback.commandFailed.title"),
                    message: String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), String(describing: apiError)),
                    recoveryAction: .retryTransfer
                )
            }
        }
        return PlaybackDisplayError(
            title: SpotiglassL10n.string("error.playback.commandFailed.title"),
            message: String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), error.localizedDescription),
            recoveryAction: .retryTransfer
        )
    }

    func fallbackNowPlaying() -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: SpotiglassL10n.string("playback.fallbackName"),
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

    var connectionStateError: PlaybackDisplayError? {
        guard case let .error(error) = connectionState else { return nil }
        return error
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

    func setConnectionState(_ state: PlaybackConnectionState) {
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
