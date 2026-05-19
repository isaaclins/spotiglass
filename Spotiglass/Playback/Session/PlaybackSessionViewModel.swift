import AppKit
import CoreAudio
import Foundation

@MainActor
final class PlaybackSessionViewModel: ObservableObject {
    @Published var connectionState: PlaybackConnectionState = .disconnected
    /// Display-only playback position anchor for smooth scrubber interpolation.
    @Published var progressAnchor: PlaybackProgressAnchor?
    @Published var deviceID: String?
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
    /// Spotify Connect devices from `GET /v1/me/player/devices`.
    @Published var connectDevices: [SpotifyConnectDevice] = []
    /// Core Audio output-capable devices (system default output picker).
    @Published var macAudioOutputDevices: [MacAudioOutputDevice] = []
    /// Current HAL default output device id (for menu checkmarks).
    @Published var systemDefaultOutputDeviceID: AudioDeviceID?
    /// Resolved SF Symbol for the playback-bar device button (hybrid: macOS output when this Web Playback device is active).
    @Published var trayOutputSymbolName = "headphones"
    @Published var isRefreshingConnectDevices = false
    @Published var playCommandAttemptedCount = 0
    @Published var playCommandDedupedCount = 0
    @Published var playCommandSentCount = 0
    @Published var playCommandSupersededCount = 0
    @Published var nextCommandAttemptedCount = 0
    @Published var nextCommandSentCount = 0
    @Published var nextCommandDroppedDedupeCount = 0
    @Published var nextCommandDroppedLockoutCount = 0
    @Published var nextCommandTimeoutUnlockCount = 0
    @Published var playbackHostReloadAttemptCount = 0
    @Published var playbackHostReloadSuppressedCooldownCount = 0
    @Published var playbackHostReloadSuppressedBudgetCount = 0
    @Published var playbackHostReuseConnectAttemptCount = 0
    @Published var playbackHostReuseSoftResetAttemptCount = 0
    @Published var playbackHostReuseSuccessCount = 0
    @Published var playbackHostRecoveryFailureCount = 0
    @Published var playbackHostReloadAttemptsByCause: [String: Int] = [:]
    @Published var playbackHostReloadSuppressedCooldownByCause: [String: Int] = [:]
    @Published var playbackHostReloadSuppressedBudgetByCause: [String: Int] = [:]
    @Published var playbackHostReuseAttemptsByCause: [String: Int] = [:]
    @Published var playbackHostRecoveryFailuresByCause: [String: Int] = [:]

    let playbackAPI: SpotifyPlaybackControlling
    let webCommander: WebPlaybackCommanding
    let macAudioOutput: MacDefaultAudioOutputProviding
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
    var transportSyncQueued = false
    var transportTransientErrorCount = 0
    var transportRateLimitedUntil: ContinuousClock.Instant?
    var localMutationSettleTicksRemaining = 0
    var isAppActive = NSApp.isActive
    var seekDispatchTask: Task<Void, Never>?
    var lastSeekSentInstant: ContinuousClock.Instant?
    var lastSentSeekPositionMilliseconds: Int?
    var hasTransferredPlaybackToCurrentDevice = false
    /// Set by `start()` and cleared by the next `.ready` event. While set, the next ready event runs
    /// the stale-Spotiglass-device auto-resume check; without it, direct `.handle(.ready)` test paths
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
        self.playbackVolume = Self.loadStoredPlaybackVolume()

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

    private static func loadStoredPlaybackVolume() -> Double {
        guard let object = UserDefaults.standard.object(forKey: playbackVolumeUserDefaultsKey) else {
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
        UserDefaults.standard.set(clamped, forKey: Self.playbackVolumeUserDefaultsKey)
        Task {
            try? await webCommander.send(.setVolume, payload: ["volume": clamped])
        }
    }

    deinit {
        togglePlayPauseAckTimeoutTask?.cancel()
        transportPollTask?.cancel()
        shuffleSyncTask?.cancel()
        repeatSyncTask?.cancel()
        seekDispatchTask?.cancel()
        deferredTransportSyncTask?.cancel()
        macAudioOutput.stopListening()
        removeAudioHardwareDevicesListenerForTeardown()
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
        if let resignedActiveObserver {
            NotificationCenter.default.removeObserver(resignedActiveObserver)
        }
    }

    static func displayError(for error: Error) -> PlaybackDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return PlaybackDisplayError(title: "Sign in again", message: "Spotify rejected the access token used for playback.", recoveryAction: .reauthenticate)
            case let .forbidden(message, _):
                return PlaybackDisplayError(title: "Spotify Premium required", message: message ?? "Spotify Web Playback SDK playback requires a Premium account.", recoveryAction: nil)
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return PlaybackDisplayError(
                    title: "Playback rate limited",
                    message: "Spotify is rate limiting playback commands. \(clause)",
                    recoveryAction: .retryTransfer
                )
            default:
                return PlaybackDisplayError(title: "Playback command failed", message: "\(apiError)", recoveryAction: .retryTransfer)
            }
        }
        return PlaybackDisplayError(title: "Playback command failed", message: error.localizedDescription, recoveryAction: .retryTransfer)
    }

    func fallbackNowPlaying() -> PlaybackNowPlaying {
        PlaybackNowPlaying(name: "Spotify playback", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 0, positionMilliseconds: 0, uri: nil)
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
        connectionState = state
        syncProgressAnchorWithConnectionState()
        restartTransportPollingIfNeeded()
    }
}
