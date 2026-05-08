import AppKit
import CoreAudio
import Foundation
import WebKit

protocol WebPlaybackCommanding {
    func loadHost()
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws
}

@MainActor
final class PlaybackSessionViewModel: ObservableObject {
    @Published private(set) var connectionState: PlaybackConnectionState = .disconnected
    @Published private(set) var deviceID: String?
    @Published private(set) var latestLog: String?
    /// The Spotify playlist ID that the current playback originated from, or
    /// `nil` if playback was started from a single track URI or external context.
    /// Used by the sidebar to highlight which playlist row is "now playing".
    @Published private(set) var activePlaylistID: String?
    /// Upcoming tracks from Web Playback SDK `track_window.next_tracks` (immediate UI).
    @Published private(set) var sdkNextTracks: [PlaybackNowPlaying] = []
    /// Web Playback SDK output gain (`player.setVolume`), 0...1. Persisted between launches.
    @Published private(set) var playbackVolume: Double
    /// From `GET /v1/me/player` for the active Spotify player (may be this device or another).
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: SpotifyRepeatMode = .off
    /// Spotify Connect devices from `GET /v1/me/player/devices`.
    @Published private(set) var connectDevices: [SpotifyConnectDevice] = []
    /// Core Audio output-capable devices (system default output picker).
    @Published private(set) var macAudioOutputDevices: [MacAudioOutputDevice] = []
    /// Current HAL default output device id (for menu checkmarks).
    @Published private(set) var systemDefaultOutputDeviceID: AudioDeviceID?
    /// Resolved SF Symbol for the playback-bar device button (hybrid: macOS output when this Web Playback device is active).
    @Published private(set) var trayOutputSymbolName = "headphones"
    @Published private(set) var isRefreshingConnectDevices = false
    @Published private(set) var playCommandAttemptedCount = 0
    @Published private(set) var playCommandDedupedCount = 0
    @Published private(set) var playCommandSentCount = 0
    @Published private(set) var playCommandSupersededCount = 0
    @Published private(set) var nextCommandAttemptedCount = 0
    @Published private(set) var nextCommandSentCount = 0
    @Published private(set) var nextCommandDroppedDedupeCount = 0
    @Published private(set) var nextCommandDroppedLockoutCount = 0
    @Published private(set) var nextCommandTimeoutUnlockCount = 0
    @Published private(set) var playbackHostReloadAttemptCount = 0
    @Published private(set) var playbackHostReloadSuppressedCooldownCount = 0
    @Published private(set) var playbackHostReloadSuppressedBudgetCount = 0
    @Published private(set) var playbackHostReuseConnectAttemptCount = 0
    @Published private(set) var playbackHostReuseSoftResetAttemptCount = 0
    @Published private(set) var playbackHostReuseSuccessCount = 0
    @Published private(set) var playbackHostRecoveryFailureCount = 0
    @Published private(set) var playbackHostReloadAttemptsByCause: [String: Int] = [:]
    @Published private(set) var playbackHostReloadSuppressedCooldownByCause: [String: Int] = [:]
    @Published private(set) var playbackHostReloadSuppressedBudgetByCause: [String: Int] = [:]
    @Published private(set) var playbackHostReuseAttemptsByCause: [String: Int] = [:]
    @Published private(set) var playbackHostRecoveryFailuresByCause: [String: Int] = [:]

    private let playbackAPI: SpotifyPlaybackControlling
    private let webCommander: WebPlaybackCommanding
    private let macAudioOutput: MacDefaultAudioOutputProviding
    /// Core Audio listener; accessed from `deinit` for removal — must be `nonisolated(unsafe)`.
    nonisolated(unsafe) private var hardwareDevicesListener: AudioObjectPropertyListenerBlock?
    private var latestPlayerSnapshot: SpotifyPlayerSnapshot?
    private var becameActiveObserver: NSObjectProtocol?
    private var resignedActiveObserver: NSObjectProtocol?
    private let progressTickInterval: TimeInterval
    private let clock = ContinuousClock()
    private let pendingShuffleTimeout: Duration
    private let pendingRepeatTimeout: Duration
    private let pendingSeekTimeout: Duration
    private let repeatWriteMinInterval: Duration
    private let postShuffleSyncDelay: Duration
    private let postRepeatSyncDelay: Duration
    private let seekRateLimitInterval: Duration
    private let seekDeduplicationWindowMilliseconds: Int
    private let seekMatchToleranceMilliseconds: Int
    /// Sliding window in which automatic transfers (auto-resume + ensure-before-play) are budgeted.
    /// User-initiated retries and manual Connect picks bypass the count but still respect the 429 cooldown.
    private let autoTransferRollingWindow: Duration
    private let autoTransferRollingWindowMax: Int
    /// Cooldown applied after a 429 with no `Retry-After`, so the next attempt is paced even when Spotify omits the hint.
    private let transferDefaultCooldown: Duration
    private var progressTickerTask: Task<Void, Never>?
    private var transportPollTask: Task<Void, Never>?
    private var shuffleSyncTask: Task<Void, Never>?
    private var repeatSyncTask: Task<Void, Never>?
    private var transportSyncInFlight = false
    private var transportSyncQueued = false
    private var transportTransientErrorCount = 0
    private var transportRateLimitedUntil: ContinuousClock.Instant?
    private var localMutationSettleTicksRemaining = 0
    private var isAppActive = NSApp.isActive
    private var seekDispatchTask: Task<Void, Never>?
    private var lastProgressTickInstant: ContinuousClock.Instant?
    private var lastSeekSentInstant: ContinuousClock.Instant?
    private var lastSentSeekPositionMilliseconds: Int?
    private var hasTransferredPlaybackToCurrentDevice = false
    /// Set by `start()` and cleared by the next `.ready` event. While set, the next ready event runs
    /// the stale-Spotiglass-device auto-resume check; without it, direct `.handle(.ready)` test paths
    /// (which never go through `start()`) keep their previous behavior and don't fetch Connect devices.
    private var autoResumeOnNextReady = false
    /// Timestamps of recent transfer PUTs, pruned to ``autoTransferRollingWindow``. Drives the
    /// rolling-window budget so a degraded auto-resume / ensure path cannot retry-storm Spotify.
    private var transferAttemptInstants: [ContinuousClock.Instant] = []
    /// Set when Spotify replies 429 (or a transfer otherwise warrants pacing); transfer attempts
    /// throw `.rateLimited` until this instant elapses. Cleared on `start()` and `disconnect()`.
    private var transferRetryCooldownUntil: ContinuousClock.Instant?
    /// Single-flight guard for transfer requests. New callers await this task before issuing their
    /// own `PUT /v1/me/player`, which collapses concurrent play() bursts to one effective transfer.
    private var inflightTransferTask: Task<Bool, Error>?
    private var inflightTransferSerial: UInt64 = 0
    private var activeInflightTransferSerial: UInt64?
    /// Expected repeat mode after an optimistic local toggle. While pending,
    /// stale transport reads from Spotify are ignored for a short window so the
    /// button does not snap back.
    private var pendingRepeatMode: SpotifyRepeatMode?
    private var pendingRepeatDeadline: ContinuousClock.Instant?
    private var confirmedRepeatMode: SpotifyRepeatMode = .off
    private var repeatWriteInFlight = false
    private var desiredRepeatMode: SpotifyRepeatMode?
    private var lastRepeatWriteAt: ContinuousClock.Instant?
    private var lastRepeatCommandedMode: SpotifyRepeatMode?
    /// Expected shuffle state after an optimistic local toggle. Stale transport
    /// reads are ignored while this short-lived expectation is pending.
    private var pendingShuffleEnabled: Bool?
    private var pendingShuffleDeadline: ContinuousClock.Instant?
    private var queuedSeekPositionMilliseconds: Int?
    private var coalescedSeekPositionMilliseconds: Int?
    private var pendingSeekDisplayPositionMilliseconds: Int?
    private var pendingSeekDeadline: ContinuousClock.Instant?
    private var pendingShuffleMutationVersion: UInt64?
    private var shuffleMutationVersion: UInt64 = 0
    private var inFlightShuffleTarget: Bool?
    private var queuedShuffleTarget: Bool?
    private var lastConfirmedShuffleEnabled: Bool?
    private var connectDevicesRefreshTask: Task<[SpotifyConnectDevice], Error>?
    private var lastConnectDevicesRefreshAt: ContinuousClock.Instant?
    private let connectDevicesFreshnessWindow: Duration
    private let playbackHostHardReloadCooldown: Duration
    private let playbackHostHardReloadWindow: Duration
    private let playbackHostHardReloadWindowMax: Int
    private let playbackHostRecoveryConnectTimeout: Duration
    private let playbackHostRecoverySoftResetTimeout: Duration
    private var playbackHostHardReloadInstants: [ContinuousClock.Instant] = []

    /// URI the user most recently asked to play. While set, any incoming
    /// Web Playback SDK `state_changed` event whose track URI does not match
    /// this URI is ignored as stale. The Spotify SDK can briefly emit a final
    /// event for the previous track during a transition, which would otherwise
    /// cause the now-playing display to flash back to the old song name.
    private var pendingPlayURI: String?
    private var pendingPlayURIDeadline: ContinuousClock.Instant?
    /// Maximum time we'll suppress mismatched events while waiting for the
    /// Spotify SDK to confirm the requested URI. After this window we fall
    /// back to whatever the SDK reports so the UI cannot deadlock on a track
    /// that Spotify ultimately refused to play.
    private let pendingPlayURITimeout: Duration = .seconds(6)

    /// True while a `previous`/`next` Web API call is in flight. Drives a UI
    /// disable on the skip buttons and short-circuits subsequent skip presses
    /// so a held hotkey or rage click cannot stack `POST /v1/me/player/previous`
    /// (or `/next`) requests.
    @Published private(set) var isSkipCommandPending = false
    @Published private(set) var isNextCommandLockedOut = false
    /// Last time a skip command was dispatched. Combined with
    /// ``skipCommandMinimumSpacing``, this enforces a minimum interval between
    /// successive `previous`/`next` POSTs even when a request returns quickly.
    private var lastSkipDispatchInstant: ContinuousClock.Instant?
    /// Minimum spacing between consecutive skip POSTs. Test paths can lower
    /// this so unit tests do not have to sleep the production cooldown.
    private let skipCommandMinimumSpacing: Duration
    private let skipCommandLockoutTimeout: Duration
    private var pendingSkipExpectedPreviousURI: String?
    private var pendingSkipDeadline: ContinuousClock.Instant?
    private let playCommandDedupeWindow: Duration
    private var inFlightPlayCommandKey: PlayCommandKey?
    private var inFlightPlayCommandID: UInt64?
    private var lastDispatchedPlayCommandKey: PlayCommandKey?
    private var lastDispatchedPlayCommandInstant: ContinuousClock.Instant?
    private var playCommandSequence: UInt64 = 0
    private var controlCommandsInFlight = 0
    private var transportSyncDeferredWhileControlCommandInFlight = false
    private var deferredTransportSyncTask: Task<Void, Never>?

    /// True when the Web Playback path is far enough along for transport actions (mirrors transport button enablement).
    var isPlaybackTransportReady: Bool {
        switch connectionState {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
        }
    }

    struct PlayCommandTriggerRoute: Equatable {
        let trigger: String
        let viewPath: String
        let entrypoint: String
        let endpointPath: String
    }

    enum PlaybackHostRecoveryCause: String {
        case startupTask = "view_startup"
        case manualReconnect = "manual_reconnect"
        case initializationError = "initialization_error"
        case notReady = "not_ready"
        case missingDeviceRetryTransfer = "missing_device_retry_transfer"
    }

    /// Canonical map of UI/state triggers that can dispatch `PUT /v1/me/player/play`.
    static let playCommandTriggerMatrix: [PlayCommandTriggerRoute] = [
        .init(
            trigger: "Track row tap / command palette play URI / pinned track activation",
            viewPath: "Spotiglass/Views/PlaylistBrowserView.swift",
            entrypoint: "play(uri:)",
            endpointPath: "/v1/me/player/play"
        ),
        .init(
            trigger: "Playlist/artist clicked-track playback",
            viewPath: "Spotiglass/Views/PlaylistBrowserView.swift",
            entrypoint: "playFromPlaylist(clickedURI:playableURIs:playlistID:)",
            endpointPath: "/v1/me/player/play"
        ),
        .init(
            trigger: "Artist album context playback",
            viewPath: "Spotiglass/Views/ArtistDetailView.swift",
            entrypoint: "play(contextURI:)",
            endpointPath: "/v1/me/player/play"
        ),
        .init(
            trigger: "Queue panel play-now action",
            viewPath: "Spotiglass/Views/QueuePanelView.swift",
            entrypoint: "play(uri:)",
            endpointPath: "/v1/me/player/play"
        )
    ]

    /// True while a toggle command is in flight until the bridge ACK or timeout (avoids overlapping SDK toggles).
    private var togglePlayPauseAwaitingBridgeAck = false
    private var togglePlayPauseAckTimeoutTask: Task<Void, Never>?
    private static let togglePlayPauseAckTimeout: Duration = .seconds(3)

    private static let playbackVolumeUserDefaultsKey = "spotiglass.playbackVolume"
    /// Matches the default passed to `Spotify.Player({ volume: … })` in the embedded host HTML.
    static let defaultPlaybackVolume: Double = 0.8

    init(
        playbackAPI: SpotifyPlaybackControlling,
        webCommander: WebPlaybackCommanding,
        macAudioOutput: MacDefaultAudioOutputProviding = MacDefaultAudioOutputNameProvider(),
        progressTickInterval: TimeInterval = 0.25,
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
        self.progressTickInterval = progressTickInterval
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

    private func syncPlaybackVolumeToWebPlayer() async {
        try? await webCommander.send(.setVolume, payload: ["volume": playbackVolume])
    }

    deinit {
        togglePlayPauseAckTimeoutTask?.cancel()
        progressTickerTask?.cancel()
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

    func start(recoveryCause: PlaybackHostRecoveryCause = .manualReconnect) {
        switch connectionState {
        case .disconnected, .error, .unavailable:
            break
        case .connecting, .ready, .transferring, .playing, .paused:
            return
        }
        let enforceHardReloadBudget = recoveryCause != .manualReconnect
        guard registerHardReloadAttempt(cause: recoveryCause, enforceBudget: enforceHardReloadBudget) else {
            return
        }
        playbackHostReloadAttemptCount += 1
        bumpCounter(&playbackHostReloadAttemptsByCause, key: recoveryCause.rawValue)
        hasTransferredPlaybackToCurrentDevice = false
        autoResumeOnNextReady = true
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        setConnectionState(.connecting)
        deviceID = nil
        webCommander.loadHost()
        Task {
            try? await webCommander.send(.connect, payload: [:])
        }
    }

    private func registerHardReloadAttempt(cause: PlaybackHostRecoveryCause, enforceBudget: Bool = true) -> Bool {
        if !enforceBudget {
            return true
        }
        let now = clock.now
        prunePlaybackHostHardReloadWindow(now: now)
        if let last = playbackHostHardReloadInstants.last,
           now < last.advanced(by: playbackHostHardReloadCooldown) {
            playbackHostReloadSuppressedCooldownCount += 1
            bumpCounter(&playbackHostReloadSuppressedCooldownByCause, key: cause.rawValue)
            latestLog = "Playback host hard reload suppressed by cooldown (\(cause.rawValue))."
            return false
        }
        if playbackHostHardReloadInstants.count >= playbackHostHardReloadWindowMax {
            playbackHostReloadSuppressedBudgetCount += 1
            bumpCounter(&playbackHostReloadSuppressedBudgetByCause, key: cause.rawValue)
            latestLog = "Playback host hard reload suppressed by budget (\(cause.rawValue))."
            return false
        }
        playbackHostHardReloadInstants.append(now)
        return true
    }

    private func bumpCounter(_ counter: inout [String: Int], key: String) {
        counter[key, default: 0] += 1
    }

    private func prunePlaybackHostHardReloadWindow(now: ContinuousClock.Instant) {
        let cutoff = now.advanced(by: .zero - playbackHostHardReloadWindow)
        playbackHostHardReloadInstants.removeAll { $0 < cutoff }
    }

    private func isPlaybackReadyStateForRecovery() -> Bool {
        switch connectionState {
        case .ready, .playing, .paused, .transferring:
            return true
        case .disconnected, .connecting, .unavailable, .error:
            return false
        }
    }

    private func waitForPlaybackReadyAfterRecovery(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        let pollInterval = min(timeout, .milliseconds(25))
        while clock.now < deadline {
            if isPlaybackReadyStateForRecovery() {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return isPlaybackReadyStateForRecovery()
    }

    private func attemptPlaybackHostRecovery(cause: PlaybackHostRecoveryCause) async {
        guard !isPlaybackReadyStateForRecovery() else { return }

        playbackHostReuseConnectAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.connect, payload: [:])
        if await waitForPlaybackReadyAfterRecovery(timeout: playbackHostRecoveryConnectTimeout) {
            playbackHostReuseSuccessCount += 1
            return
        }

        playbackHostReuseSoftResetAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.disconnect, payload: [:])
        try? await Task.sleep(for: min(playbackHostRecoverySoftResetTimeout, .milliseconds(200)))
        try? await webCommander.send(.connect, payload: [:])
        if await waitForPlaybackReadyAfterRecovery(timeout: playbackHostRecoverySoftResetTimeout) {
            playbackHostReuseSuccessCount += 1
            return
        }

        let previousState = connectionState
        start(recoveryCause: cause)
        if previousState == connectionState {
            playbackHostRecoveryFailureCount += 1
            bumpCounter(&playbackHostRecoveryFailuresByCause, key: cause.rawValue)
        }
    }

    func handle(_ event: PlaybackBridgeEvent) {
        switch event {
        case let .ready(deviceID):
            if self.deviceID != deviceID {
                hasTransferredPlaybackToCurrentDevice = false
            }
            self.deviceID = deviceID
            setConnectionState(.ready(deviceID: deviceID))
            // WebKit helper PIDs (WebContent, GPU, …) may spawn only after the Web
            // Playback SDK is ready. Rebuild the equalizer tap so Core Audio includes them.
            NotificationCenter.default.post(name: .spotiglassPlaybackDeviceReady, object: nil)
            refreshTrayOutputSymbol()
            let shouldAutoResume = autoResumeOnNextReady
            autoResumeOnNextReady = false
            Task {
                await syncPlaybackVolumeToWebPlayer()
                if shouldAutoResume {
                    await autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: deviceID)
                }
            }
        case let .notReady(deviceID):
            if self.deviceID == deviceID {
                self.deviceID = nil
            }
            hasTransferredPlaybackToCurrentDevice = false
            clearPendingSkipCommand()
            sdkNextTracks = []
            setConnectionState(.unavailable("Spotify playback device is no longer available. Reconnect playback to continue."))
            Task {
                await attemptPlaybackHostRecovery(cause: .notReady)
            }
        case let .stateChanged(nowPlaying, isPaused, nextTracks):
            observeSkipAdvance(nowPlayingURI: nowPlaying?.uri)
            if shouldSuppressStaleStateChange(nowPlaying: nowPlaying) {
                return
            }
            sdkNextTracks = nextTracks
            let effectiveNowPlaying = applyPendingSeekSuppression(to: nowPlaying)
            if effectiveNowPlaying != nil {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(isPaused ? .paused(effectiveNowPlaying) : .playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        case let .playerCommandFinished(command):
            if command == "togglePlay" {
                clearTogglePlayPauseAckWait()
            }
        case let .initializationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Playback could not start", message: message, recoveryAction: .reconnect)))
            Task {
                await attemptPlaybackHostRecovery(cause: .initializationError)
            }
        case let .authenticationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Sign in again", message: message, recoveryAction: .reauthenticate)))
        case let .accountError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Spotify Premium required", message: message, recoveryAction: nil)))
        case let .playbackError(message):
            clearTogglePlayPauseAckWait()
            setConnectionState(.error(PlaybackDisplayError(title: "Playback error", message: message, recoveryAction: .retryTransfer)))
        case let .log(message):
            latestLog = message
        }
    }

    func play(uri: String) async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(
                title: "Playback device unavailable",
                message: "The Spotify Web Playback SDK has not reported a ready device yet.",
                recoveryAction: .reconnect
            )))
            return
        }

        activePlaylistID = nil
        let commandKey = PlayCommandKey.singleURI(deviceID: deviceID, uri: uri)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }
        beginPendingPlay(uri: uri)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uri: uri, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: uri) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": uri])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func play(contextURI: String) async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(
                title: "Playback device unavailable",
                message: "The Spotify Web Playback SDK has not reported a ready device yet.",
                recoveryAction: .reconnect
            )))
            return
        }

        activePlaylistID = nil
        let commandKey = PlayCommandKey.contextURI(deviceID: deviceID, contextURI: contextURI)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(contextURI: contextURI, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            try await webCommander.send(.playURI, payload: ["uri": contextURI])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func playFromPlaylist(clickedURI: String, playableURIs: [String], playlistID: String? = nil) async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(
                title: "Playback device unavailable",
                message: "The Spotify Web Playback SDK has not reported a ready device yet.",
                recoveryAction: .reconnect
            )))
            return
        }

        guard let startIndex = playableURIs.firstIndex(of: clickedURI) else {
            await play(uri: clickedURI)
            return
        }

        let queue = Array(playableURIs[startIndex...])
        guard !queue.isEmpty else {
            await play(uri: clickedURI)
            return
        }

        activePlaylistID = playlistID
        let commandKey = PlayCommandKey.uriQueue(
            deviceID: deviceID,
            headURI: clickedURI,
            queueCount: queue.count
        )
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }
        beginPendingPlay(uri: clickedURI)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uris: queue, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: clickedURI) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": clickedURI])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func togglePlayPause() async {
        guard !togglePlayPauseAwaitingBridgeAck else { return }
        togglePlayPauseAwaitingBridgeAck = true
        scheduleTogglePlayPauseAckTimeout()
        do {
            try await webCommander.send(.togglePlay, payload: [:])
        } catch {
            clearTogglePlayPauseAckWait()
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    private func scheduleTogglePlayPauseAckTimeout() {
        togglePlayPauseAckTimeoutTask?.cancel()
        togglePlayPauseAckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.togglePlayPauseAckTimeout)
            await MainActor.run {
                self?.clearTogglePlayPauseAckWait()
            }
        }
    }

    private func clearTogglePlayPauseAckWait() {
        togglePlayPauseAckTimeoutTask?.cancel()
        togglePlayPauseAckTimeoutTask = nil
        togglePlayPauseAwaitingBridgeAck = false
    }

    func previous() async {
        await dispatchSkipCommand(.previous)
    }

    func next() async {
        await dispatchSkipCommand(.next)
    }

    private enum SkipCommandKind {
        case previous
        case next
    }

    /// Serializes Web API skip POSTs from every entry point (button, hotkey,
    /// command palette row). The same gate covers both `previous` and `next` so
    /// a fast Prev → Next → Prev burst from a held hotkey, an auto-repeat
    /// firehose that slipped through, or a rage click cannot stack overlapping
    /// requests against `POST /v1/me/player/{previous,next}`.
    private func dispatchSkipCommand(_ kind: SkipCommandKind) async {
        if kind == .next {
            nextCommandAttemptedCount += 1
        }
        if isSkipCommandPending {
            if kind == .next {
                nextCommandDroppedLockoutCount += 1
            }
            return
        }
        if case .transferring = connectionState {
            return
        }
        let now = clock.now
        if kind == .next,
           let deadline = pendingSkipDeadline {
            if now < deadline {
                nextCommandDroppedLockoutCount += 1
                return
            }
            pendingSkipDeadline = nil
            pendingSkipExpectedPreviousURI = nil
            isNextCommandLockedOut = false
            nextCommandTimeoutUnlockCount += 1
        }
        if let last = lastSkipDispatchInstant,
           now < last.advanced(by: skipCommandMinimumSpacing) {
            if kind == .next {
                nextCommandDroppedDedupeCount += 1
            }
            return
        }
        lastSkipDispatchInstant = now
        isSkipCommandPending = true
        let expectedPreviousURI = currentNowPlayingURI
        await sendDeviceCommand { [playbackAPI] deviceID in
            try await performPrioritizedControlCommand {
                switch kind {
                case .previous:
                    try await playbackAPI.previous(deviceID: deviceID)
                case .next:
                    try await playbackAPI.next(deviceID: deviceID)
                }
            }
        }
        isSkipCommandPending = false
        guard connectionStateError == nil else {
            pendingSkipDeadline = nil
            pendingSkipExpectedPreviousURI = nil
            return
        }
        if kind == .next {
            pendingSkipExpectedPreviousURI = expectedPreviousURI
            pendingSkipDeadline = now.advanced(by: skipCommandLockoutTimeout)
            isNextCommandLockedOut = true
            nextCommandSentCount += 1
        }
    }

    private func observeSkipAdvance(nowPlayingURI: String?) {
        guard let expectedPreviousURI = pendingSkipExpectedPreviousURI else { return }
        guard let nowPlayingURI, nowPlayingURI != expectedPreviousURI else { return }
        pendingSkipExpectedPreviousURI = nil
        pendingSkipDeadline = nil
        isNextCommandLockedOut = false
    }

    private func clearPendingSkipCommand() {
        isSkipCommandPending = false
        pendingSkipExpectedPreviousURI = nil
        pendingSkipDeadline = nil
        isNextCommandLockedOut = false
    }

    private var currentNowPlayingURI: String? {
        switch connectionState {
        case let .playing(nowPlaying):
            return nowPlaying.uri
        case let .paused(nowPlaying):
            return nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    private var connectionStateError: PlaybackDisplayError? {
        guard case let .error(error) = connectionState else { return nil }
        return error
    }

    /// Refreshes shuffle/repeat from Spotify (`GET /v1/me/player`). Safe to call from UI and poll paths.
    /// Concurrent calls are coalesced so only one in-flight request runs at a time.
    func syncTransportFromSpotify(minimumShuffleMutationVersion: UInt64? = nil) async {
        guard controlCommandsInFlight == 0 else {
            transportSyncDeferredWhileControlCommandInFlight = true
            return
        }
        if transportSyncInFlight {
            transportSyncQueued = true
            return
        }

        repeat {
            transportSyncQueued = false
            transportSyncInFlight = true
            defer { transportSyncInFlight = false }

            do {
                if let snapshot = try await playbackAPI.fetchPlayerSnapshot() {
                    latestPlayerSnapshot = snapshot
                    applyTransportShuffleEnabled(
                        snapshot.transport.shuffle,
                        minimumMutationVersion: minimumShuffleMutationVersion
                    )
                    applyTransportRepeatMode(snapshot.transport.repeatMode)
                } else {
                    latestPlayerSnapshot = nil
                }
                transportTransientErrorCount = 0
                transportRateLimitedUntil = nil
                if localMutationSettleTicksRemaining > 0 {
                    localMutationSettleTicksRemaining -= 1
                }
                refreshTrayOutputSymbol()
            } catch {
                applyTransportPollingBackoff(for: error)
                // Polling should not surface transport read failures as playback errors.
            }
        } while transportSyncQueued

        restartTransportPollingIfNeeded()
    }

    private func applyTransportPollingBackoff(for error: Error) {
        guard let apiError = error as? SpotifyAPIError else {
            transportTransientErrorCount = 0
            return
        }
        switch apiError {
        case let .rateLimited(retryAfter):
            let retryDelay = max(1, retryAfter ?? 15)
            transportRateLimitedUntil = clock.now.advanced(by: .seconds(retryDelay))
            transportTransientErrorCount = 0
        case let .server(statusCode, _, _) where statusCode >= 500:
            transportTransientErrorCount = min(transportTransientErrorCount + 1, 4)
        case .network:
            transportTransientErrorCount = min(transportTransientErrorCount + 1, 4)
        default:
            transportTransientErrorCount = 0
        }
    }

    func refreshConnectDevices(force: Bool = false) async {
        if !force,
           let lastConnectDevicesRefreshAt,
           clock.now < lastConnectDevicesRefreshAt.advanced(by: connectDevicesFreshnessWindow) {
            return
        }

        if let inFlight = connectDevicesRefreshTask {
            isRefreshingConnectDevices = true
            defer { isRefreshingConnectDevices = false }
            do {
                connectDevices = try await inFlight.value
                lastConnectDevicesRefreshAt = clock.now
                refreshTrayOutputSymbol()
            } catch {
                connectDevices = []
            }
            return
        }

        let refreshTask = Task {
            try await playbackAPI.fetchAvailableDevices()
        }
        connectDevicesRefreshTask = refreshTask
        isRefreshingConnectDevices = true
        defer {
            isRefreshingConnectDevices = false
            connectDevicesRefreshTask = nil
        }
        do {
            connectDevices = try await refreshTask.value
            lastConnectDevicesRefreshAt = clock.now
            refreshTrayOutputSymbol()
        } catch {
            connectDevices = []
        }
    }

    func refreshMacAudioOutputDevices() {
        macAudioOutputDevices = MacAudioOutputHardware.enumerateOutputDevices()
        systemDefaultOutputDeviceID = MacAudioOutputHardware.defaultOutputDeviceID()
    }

    func setSystemDefaultOutputDevice(_ audioDeviceID: AudioDeviceID) {
        let status = MacAudioOutputHardware.setDefaultOutputDevice(audioDeviceID)
        guard status == noErr else { return }
        refreshMacAudioOutputDevices()
        refreshTrayOutputSymbol()
    }

    private func installAudioHardwareDevicesListener() {
        removeAudioHardwareDevicesListenerForTeardown()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshMacAudioOutputDevices()
            }
        }
        hardwareDevicesListener = listener
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, listener)
    }

    nonisolated private func removeAudioHardwareDevicesListenerForTeardown() {
        guard let block = hardwareDevicesListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
        hardwareDevicesListener = nil
    }

    func transferPlayback(toConnectDevice selectedDeviceID: String) async {
        let shouldPlay: Bool
        switch connectionState {
        case .playing:
            shouldPlay = true
        default:
            shouldPlay = false
        }
        do {
            try await performPrioritizedControlCommand {
                try await self.performTransfer(deviceID: selectedDeviceID, play: shouldPlay, origin: .userManualConnect)
            }
            if selectedDeviceID == deviceID {
                hasTransferredPlaybackToCurrentDevice = true
            } else {
                hasTransferredPlaybackToCurrentDevice = false
            }
            noteLocalPlaybackMutation()
            await syncTransportFromSpotify()
            await refreshConnectDevices(force: true)
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    private func refreshTrayOutputSymbol() {
        let localID = deviceID
        let active = latestPlayerSnapshot?.activeDevice

        if let localID, let active, active.deviceID == localID {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: macAudioOutput.currentOutputDisplayName,
                spotifyDeviceType: "computer"
            )
            return
        }

        if let active {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: active.name,
                spotifyDeviceType: active.type
            )
            return
        }

        if localID != nil {
            trayOutputSymbolName = PlaybackOutputSFResolver.symbolName(
                deviceName: macAudioOutput.currentOutputDisplayName,
                spotifyDeviceType: "computer"
            )
            return
        }

        trayOutputSymbolName = "headphones"
    }

    func toggleShuffle() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let target = !shuffleEnabled
        shuffleEnabled = target
        let mutationVersion = nextShuffleMutationVersion()
        setPendingShuffle(enabled: target, mutationVersion: mutationVersion)

        // Avoid writes when the target is already confirmed from Spotify transport.
        if lastConfirmedShuffleEnabled == target {
            clearPendingShuffle()
            return
        }
        // Avoid duplicate writes while the same target is already in flight.
        if inFlightShuffleTarget == target {
            return
        }
        // Coalesce rapid toggles to a single follow-up write target.
        if inFlightShuffleTarget != nil {
            queuedShuffleTarget = target
            return
        }

        var nextTarget: Bool? = target
        var nextMutationVersion: UInt64 = mutationVersion
        while let requestedTarget = nextTarget {
            inFlightShuffleTarget = requestedTarget
            do {
                try await performPrioritizedControlCommand {
                    try await playbackAPI.setShuffle(enabled: requestedTarget, deviceID: deviceID)
                }
                lastConfirmedShuffleEnabled = requestedTarget
                scheduleTransportSyncAfterShuffleToggle(minimumMutationVersion: nextMutationVersion)
            } catch {
                inFlightShuffleTarget = nil
                queuedShuffleTarget = nil
                clearPendingShuffle()
                let fallback = lastConfirmedShuffleEnabled ?? !requestedTarget
                if shuffleEnabled == requestedTarget {
                    shuffleEnabled = fallback
                }
                setConnectionState(.error(Self.displayError(for: error)))
                return
            }
            inFlightShuffleTarget = nil

            guard let queuedTarget = queuedShuffleTarget else {
                return
            }
            queuedShuffleTarget = nil
            if lastConfirmedShuffleEnabled == queuedTarget {
                if shuffleEnabled != queuedTarget {
                    shuffleEnabled = queuedTarget
                }
                clearPendingShuffle()
                return
            }
            nextTarget = queuedTarget
            nextMutationVersion = nextShuffleMutationVersion()
            setPendingShuffle(enabled: queuedTarget, mutationVersion: nextMutationVersion)
            shuffleEnabled = queuedTarget
        }
    }

    func cycleRepeat() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let nextMode = repeatMode.next
        repeatMode = nextMode
        desiredRepeatMode = nextMode
        setPendingRepeat(mode: nextMode)
        await flushDesiredRepeatWrites(deviceID: deviceID)
    }

    private func flushDesiredRepeatWrites(deviceID: String) async {
        guard !repeatWriteInFlight else { return }

        while let targetMode = desiredRepeatMode {
            if shouldSkipRepeatWrite(targetMode: targetMode) {
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                continue
            }

            await sleepIfInsideRepeatWriteWindow()
            repeatWriteInFlight = true

            do {
                try await performPrioritizedControlCommand {
                    try await playbackAPI.setRepeat(mode: targetMode, deviceID: deviceID)
                }
                lastRepeatWriteAt = clock.now
                lastRepeatCommandedMode = targetMode
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                scheduleTransportSyncAfterRepeatToggle()
            } catch {
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                clearPendingRepeat()
                if repeatMode == targetMode {
                    repeatMode = confirmedRepeatMode
                }
                setConnectionState(.error(Self.displayError(for: error)))
            }

            repeatWriteInFlight = false
        }
    }

    private func shouldSkipRepeatWrite(targetMode: SpotifyRepeatMode) -> Bool {
        if targetMode == confirmedRepeatMode {
            if repeatWriteInFlight {
                return false
            }
            if let lastCommanded = lastRepeatCommandedMode, lastCommanded != targetMode {
                return false
            }
            if let pendingMode = pendingRepeatMode, pendingMode != targetMode {
                return false
            }
            return true
        }
        if targetMode == pendingRepeatMode, targetMode == lastRepeatCommandedMode {
            return true
        }
        return false
    }

    private func sleepIfInsideRepeatWriteWindow() async {
        guard let lastRepeatWriteAt else { return }
        let nextEligibleWriteAt = lastRepeatWriteAt.advanced(by: repeatWriteMinInterval)
        guard clock.now < nextEligibleWriteAt else { return }
        do {
            try await clock.sleep(until: nextEligibleWriteAt, tolerance: .milliseconds(20))
        } catch {
            // Cancellation means this pacing wait can be safely abandoned.
        }
    }

    func seek(to milliseconds: Int) async {
        enqueueSeek(milliseconds: milliseconds)
    }

    func disconnect() async {
        do {
            try await webCommander.send(.disconnect, payload: [:])
        } catch {
            latestLog = error.localizedDescription
        }
        deviceID = nil
        hasTransferredPlaybackToCurrentDevice = false
        activePlaylistID = nil
        sdkNextTracks = []
        shuffleEnabled = false
        lastConfirmedShuffleEnabled = nil
        inFlightShuffleTarget = nil
        queuedShuffleTarget = nil
        pendingShuffleMutationVersion = nil
        shuffleMutationVersion = 0
        repeatMode = .off
        confirmedRepeatMode = .off
        latestPlayerSnapshot = nil
        connectDevices = []
        lastConnectDevicesRefreshAt = nil
        connectDevicesRefreshTask?.cancel()
        connectDevicesRefreshTask = nil
        trayOutputSymbolName = "headphones"
        clearPendingShuffle()
        clearPendingRepeat()
        repeatWriteInFlight = false
        desiredRepeatMode = nil
        lastRepeatWriteAt = nil
        lastRepeatCommandedMode = nil
        clearPendingPlay()
        inFlightPlayCommandID = nil
        inFlightPlayCommandKey = nil
        transportSyncDeferredWhileControlCommandInFlight = false
        deferredTransportSyncTask?.cancel()
        deferredTransportSyncTask = nil
        clearPendingSkipCommand()
        clearPendingSeek()
        seekDispatchTask?.cancel()
        seekDispatchTask = nil
        lastSeekSentInstant = nil
        lastSentSeekPositionMilliseconds = nil
        transportTransientErrorCount = 0
        transportRateLimitedUntil = nil
        localMutationSettleTicksRemaining = 0
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        playbackHostHardReloadInstants.removeAll()
        inflightTransferTask = nil
        activeInflightTransferSerial = nil
        clearTogglePlayPauseAckWait()
        setConnectionState(.disconnected)
    }

    /// Retries Spotify “transfer playback” to this device after API or transport failures that set `recoveryAction` to `.retryTransfer`.
    /// If no device ID is known, falls back to `start()` (full Web Playback SDK reconnect).
    func retryPlaybackTransfer() async {
        guard let deviceID else {
            guard registerHardReloadAttempt(cause: .missingDeviceRetryTransfer, enforceBudget: true) else {
                return
            }
            playbackHostReloadAttemptCount += 1
            bumpCounter(&playbackHostReloadAttemptsByCause, key: PlaybackHostRecoveryCause.missingDeviceRetryTransfer.rawValue)
            hasTransferredPlaybackToCurrentDevice = false
            autoResumeOnNextReady = true
            transferAttemptInstants.removeAll()
            transferRetryCooldownUntil = nil
            setConnectionState(.connecting)
            self.deviceID = nil
            webCommander.loadHost()
            Task {
                try? await webCommander.send(.connect, payload: [:])
            }
            return
        }
        hasTransferredPlaybackToCurrentDevice = false
        do {
            setConnectionState(.transferring(deviceID: deviceID))
            try await performTransfer(deviceID: deviceID, play: false, origin: .userRetry)
            hasTransferredPlaybackToCurrentDevice = true
            setConnectionState(.ready(deviceID: deviceID))
            noteLocalPlaybackMutation()
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    private func sendDeviceCommand(action: (String) async throws -> Void) async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        do {
            try await action(deviceID)
            noteLocalPlaybackMutation()
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
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

    private func fallbackNowPlaying() -> PlaybackNowPlaying {
        PlaybackNowPlaying(name: "Spotify playback", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 0, positionMilliseconds: 0, uri: nil)
    }

    /// Runs a Spotify Web API control call while deferring `syncTransportFromSpotify()` reads so
    /// `GET /v1/me/player` does not race overlapping `PUT`/`POST` playback commands.
    private func performPrioritizedControlCommand(_ operation: () async throws -> Void) async rethrows {
        controlCommandsInFlight += 1
        defer {
            controlCommandsInFlight -= 1
            if controlCommandsInFlight == 0, transportSyncDeferredWhileControlCommandInFlight {
                transportSyncDeferredWhileControlCommandInFlight = false
                deferredTransportSyncTask?.cancel()
                deferredTransportSyncTask = Task { @MainActor [weak self] in
                    await self?.syncTransportFromSpotify()
                }
            }
        }
        try await operation()
    }

    /// Why a transfer is being requested. Drives idempotency, budget, and cooldown gating in
    /// ``runSingleTransfer(deviceID:play:origin:)`` so user-initiated commands stay responsive
    /// while automatic paths (auto-resume, ensure-before-play) cannot retry-storm Spotify.
    private enum TransferOrigin {
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

    /// Single-flight, idempotent, budget-aware funnel for `PUT /v1/me/player`. Returns `true`
    /// when a PUT was actually issued and `false` when the request was satisfied without one
    /// (e.g. Spotify already shows the target as the active device, or a sibling caller's
    /// in-flight transfer already covered the same intent).
    @discardableResult
    private func performTransfer(deviceID: String, play: Bool, origin: TransferOrigin) async throws -> Bool {
        if let inflight = inflightTransferTask {
            // Wait for the in-flight transfer; if it satisfied this caller's intent, we're done.
            _ = try? await inflight.value
            if origin.isAutomatic, deviceID == self.deviceID, hasTransferredPlaybackToCurrentDevice {
                return false
            }
        }
        let serial = inflightTransferSerial
        inflightTransferSerial &+= 1
        let task = Task<Bool, Error> { [weak self] in
            guard let self else { return false }
            return try await self.runSingleTransfer(deviceID: deviceID, play: play, origin: origin)
        }
        inflightTransferTask = task
        activeInflightTransferSerial = serial
        defer {
            if activeInflightTransferSerial == serial {
                inflightTransferTask = nil
                activeInflightTransferSerial = nil
            }
        }
        return try await task.value
    }

    private func runSingleTransfer(deviceID: String, play: Bool, origin: TransferOrigin) async throws -> Bool {
        let alreadyActive: Bool
        switch origin {
        case .userManualConnect:
            // The Connect picker is populated from a recent `GET /v1/me/player/devices`; trust it.
            alreadyActive = connectDevices.first(where: { $0.deviceID == deviceID })?.isActive == true
        case .ensureBeforePlay, .autoResume:
            alreadyActive = latestPlayerSnapshot?.activeDevice?.deviceID == deviceID
        case .userRetry:
            // Recovery is the user's explicit ask; never short-circuit it on cached state.
            alreadyActive = false
        }
        if alreadyActive {
            if (origin == .ensureBeforePlay || origin == .autoResume), deviceID == self.deviceID {
                hasTransferredPlaybackToCurrentDevice = true
            }
            return false
        }
        if let until = transferRetryCooldownUntil, clock.now < until {
            let remaining = max(Self.durationSeconds(until - clock.now), 0.5)
            throw SpotifyAPIError.rateLimited(retryAfter: remaining)
        }
        if origin.isAutomatic {
            pruneOldTransferAttempts()
            if transferAttemptInstants.count >= autoTransferRollingWindowMax {
                let windowSeconds = Self.durationSeconds(autoTransferRollingWindow)
                throw SpotifyAPIError.rateLimited(retryAfter: windowSeconds)
            }
        }
        transferAttemptInstants.append(clock.now)
        do {
            try await playbackAPI.transferPlayback(to: deviceID, play: play)
        } catch let apiError as SpotifyAPIError {
            if case let .rateLimited(retryAfter) = apiError {
                let cooldown = retryAfter ?? Self.durationSeconds(transferDefaultCooldown)
                transferRetryCooldownUntil = clock.now.advanced(by: .seconds(cooldown))
            }
            throw apiError
        }
        if (origin == .ensureBeforePlay || origin == .autoResume), deviceID == self.deviceID {
            hasTransferredPlaybackToCurrentDevice = true
        }
        return true
    }

    private func pruneOldTransferAttempts() {
        let cutoff = clock.now.advanced(by: .zero - autoTransferRollingWindow)
        transferAttemptInstants.removeAll { $0 < cutoff }
    }

    /// Seconds remaining before another transfer attempt is allowed (`nil` when no cooldown applies).
    /// Surfaced for diagnostics and tests; the UI reads the same intent indirectly through the
    /// `.rateLimited` error that ``performTransfer(deviceID:play:origin:)`` rethrows.
    func transferRetryCooldownSecondsRemaining() -> Int? {
        guard let until = transferRetryCooldownUntil else { return nil }
        let remaining = Self.durationSeconds(until - clock.now)
        guard remaining > 0 else { return nil }
        return max(1, Int(remaining.rounded(.up)))
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0
    }

    private func ensurePlaybackTransferredIfNeeded(deviceID: String) async throws {
        guard !hasTransferredPlaybackToCurrentDevice else {
            return
        }
        setConnectionState(.transferring(deviceID: deviceID))
        try await performTransfer(deviceID: deviceID, play: false, origin: .ensureBeforePlay)
    }

    /// On window reopen the previous session's `WKWebView` often lingers as the active Spotify
    /// Connect "Spotiglass" device for a few seconds. When that happens, hand playback to the
    /// freshly created device so the user keeps hearing music through the window they just
    /// reopened. Restricted to devices named ``SpotifyPlaybackHost/deviceName`` so a clean first
    /// launch never steals playback from the user's other Connect targets (phone, desktop, …).
    private func autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: String) async {
        guard !hasTransferredPlaybackToCurrentDevice else { return }
        await refreshConnectDevices(force: true)
        let devices = connectDevices
        guard let staleSpotiglass = devices.first(where: { device in
            device.isActive
                && device.name == SpotifyPlaybackHost.deviceName
                && device.deviceID != targetDeviceID
        }) else {
            return
        }
        do {
            setConnectionState(.transferring(deviceID: targetDeviceID))
            try await performTransfer(deviceID: targetDeviceID, play: true, origin: .autoResume)
            // Subsequent SDK `state_changed` will move the connection state to .playing/.paused.
            latestLog = "Auto-resumed playback from stale Spotiglass device \(staleSpotiglass.deviceID) to \(targetDeviceID)."
        } catch {
            latestLog = "Auto-resume transfer to new Spotiglass device failed: \(error.localizedDescription)"
            setConnectionState(.ready(deviceID: targetDeviceID))
        }
    }

    private func beginPendingPlay(uri: String) {
        pendingPlayURI = uri
        pendingPlayURIDeadline = clock.now.advanced(by: pendingPlayURITimeout)
    }

    private func clearPendingPlay() {
        pendingPlayURI = nil
        pendingPlayURIDeadline = nil
    }

    private struct PlayCommandDispatch {
        let id: UInt64
        let key: PlayCommandKey
    }

    private enum PlayCommandKey: Equatable {
        case singleURI(deviceID: String, uri: String)
        case contextURI(deviceID: String, contextURI: String)
        case uriQueue(deviceID: String, headURI: String, queueCount: Int)
    }

    private func beginPlayCommandDispatchIfNeeded(for key: PlayCommandKey) -> PlayCommandDispatch? {
        playCommandAttemptedCount += 1

        if inFlightPlayCommandKey == key {
            playCommandDedupedCount += 1
            return nil
        }

        if
            lastDispatchedPlayCommandKey == key,
            let lastInstant = lastDispatchedPlayCommandInstant,
            clock.now < lastInstant.advanced(by: playCommandDedupeWindow)
        {
            playCommandDedupedCount += 1
            return nil
        }

        if let inFlightPlayCommandKey, inFlightPlayCommandKey != key {
            playCommandSupersededCount += 1
        }

        playCommandSequence &+= 1
        let dispatch = PlayCommandDispatch(id: playCommandSequence, key: key)
        inFlightPlayCommandID = dispatch.id
        inFlightPlayCommandKey = key
        lastDispatchedPlayCommandKey = key
        lastDispatchedPlayCommandInstant = clock.now
        playCommandSentCount += 1
        return dispatch
    }

    private func isPlayCommandDispatchCurrent(_ dispatch: PlayCommandDispatch) -> Bool {
        inFlightPlayCommandID == dispatch.id && inFlightPlayCommandKey == dispatch.key
    }

    private func finalizePlayCommandDispatchIfCurrent(_ dispatch: PlayCommandDispatch) {
        guard isPlayCommandDispatchCurrent(dispatch) else { return }
        inFlightPlayCommandID = nil
        inFlightPlayCommandKey = nil
    }

    private func enqueueSeek(milliseconds: Int) {
        let normalized = normalizedSeekMilliseconds(milliseconds)
        if queuedSeekPositionMilliseconds == nil {
            queuedSeekPositionMilliseconds = normalized
        } else {
            coalescedSeekPositionMilliseconds = normalized
        }
        pendingSeekDisplayPositionMilliseconds = normalized
        pendingSeekDeadline = clock.now.advanced(by: pendingSeekTimeout)
        applyOptimisticSeekPosition(normalized)
        scheduleSeekDispatchIfNeeded()
    }

    private func scheduleSeekDispatchIfNeeded() {
        guard seekDispatchTask == nil else { return }
        seekDispatchTask = Task { [weak self] in
            await self?.runSeekDispatchLoop()
        }
    }

    private func runSeekDispatchLoop() async {
        defer { seekDispatchTask = nil }
        while !Task.isCancelled {
            guard let target = queuedSeekPositionMilliseconds else {
                return
            }
            queuedSeekPositionMilliseconds = nil

            if let lastSentPosition = lastSentSeekPositionMilliseconds,
               abs(target - lastSentPosition) < seekDeduplicationWindowMilliseconds {
                continue
            }

            if let lastSeekSentInstant {
                let nextEligibleInstant = lastSeekSentInstant.advanced(by: seekRateLimitInterval)
                if clock.now < nextEligibleInstant {
                    do {
                        try await clock.sleep(until: nextEligibleInstant, tolerance: .milliseconds(20))
                    } catch {
                        return
                    }
                }
            }

            lastSeekSentInstant = clock.now
            if await sendSeekCommand(milliseconds: target) {
                lastSentSeekPositionMilliseconds = target
            }
            if queuedSeekPositionMilliseconds == nil, let coalescedTarget = coalescedSeekPositionMilliseconds {
                queuedSeekPositionMilliseconds = coalescedTarget
                coalescedSeekPositionMilliseconds = nil
            }
        }
    }

    private func sendSeekCommand(milliseconds: Int) async -> Bool {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return false
        }
        do {
            try await performPrioritizedControlCommand {
                try await playbackAPI.seek(to: milliseconds, deviceID: deviceID)
            }
            return true
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
            return false
        }
    }

    private func normalizedSeekMilliseconds(_ milliseconds: Int) -> Int {
        let raw = max(0, milliseconds)
        guard let nowPlaying = currentNowPlaying else { return raw }
        guard nowPlaying.durationMilliseconds > 0 else { return raw }
        return min(raw, nowPlaying.durationMilliseconds)
    }

    private var currentNowPlaying: PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(nowPlaying):
            return nowPlaying
        case let .paused(nowPlaying):
            return nowPlaying
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    private func applyOptimisticSeekPosition(_ milliseconds: Int) {
        switch connectionState {
        case let .playing(nowPlaying):
            setConnectionState(.playing(nowPlaying.with(positionMilliseconds: milliseconds)))
        case let .paused(nowPlaying):
            if let nowPlaying {
                setConnectionState(.paused(nowPlaying.with(positionMilliseconds: milliseconds)))
            }
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            break
        }
    }

    private func clearPendingSeek() {
        queuedSeekPositionMilliseconds = nil
        coalescedSeekPositionMilliseconds = nil
        pendingSeekDisplayPositionMilliseconds = nil
        pendingSeekDeadline = nil
    }

    /// Keeps the optimistic seek position visible until Spotify catches up.
    private func applyPendingSeekSuppression(to nowPlaying: PlaybackNowPlaying?) -> PlaybackNowPlaying? {
        guard let expectedPosition = pendingSeekDisplayPositionMilliseconds else {
            return nowPlaying
        }
        if let deadline = pendingSeekDeadline, clock.now >= deadline {
            clearPendingSeek()
            return nowPlaying
        }
        guard let nowPlaying else {
            return nil
        }
        if let incomingURI = nowPlaying.uri,
           let currentURI = currentNowPlaying?.uri,
           incomingURI != currentURI {
            clearPendingSeek()
            return nowPlaying
        }
        if abs(nowPlaying.positionMilliseconds - expectedPosition) <= seekMatchToleranceMilliseconds {
            clearPendingSeek()
            return nowPlaying
        }
        return nowPlaying.with(positionMilliseconds: expectedPosition)
    }

    /// Returns true when an incoming SDK `state_changed` event should be
    /// dropped because we are still waiting for the user-requested track to
    /// take effect. Allows matching events through, lets the timeout window
    /// fall back gracefully, and lets nil-track teardown events through so
    /// the SDK can still report errors / device loss while a play is pending.
    private func shouldSuppressStaleStateChange(nowPlaying: PlaybackNowPlaying?) -> Bool {
        guard let pending = pendingPlayURI else {
            return false
        }
        if let deadline = pendingPlayURIDeadline, clock.now >= deadline {
            clearPendingPlay()
            return false
        }
        guard let eventURI = nowPlaying?.uri else {
            return false
        }
        if eventURI == pending {
            clearPendingPlay()
            return false
        }
        return true
    }

    private func optimisticNowPlaying(for uri: String) -> PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(nowPlaying), let .paused(.some(nowPlaying)):
            return nowPlaying.uri == uri ? nowPlaying : nil
        case .paused(.none), .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    private func setPendingRepeat(mode: SpotifyRepeatMode) {
        pendingRepeatMode = mode
        pendingRepeatDeadline = clock.now.advanced(by: pendingRepeatTimeout)
    }

    private func setPendingShuffle(enabled: Bool, mutationVersion: UInt64) {
        pendingShuffleEnabled = enabled
        pendingShuffleDeadline = clock.now.advanced(by: pendingShuffleTimeout)
        pendingShuffleMutationVersion = mutationVersion
    }

    private func clearPendingShuffle() {
        pendingShuffleEnabled = nil
        pendingShuffleDeadline = nil
        pendingShuffleMutationVersion = nil
    }

    private func clearPendingRepeat() {
        pendingRepeatMode = nil
        pendingRepeatDeadline = nil
    }

    /// Applies shuffle from Spotify transport while suppressing stale reads
    /// during a short optimistic-shuffle window.
    private func applyTransportShuffleEnabled(_ transportShuffle: Bool, minimumMutationVersion: UInt64?) {
        if let minimumMutationVersion, minimumMutationVersion < shuffleMutationVersion {
            return
        }
        guard let expected = pendingShuffleEnabled else {
            shuffleEnabled = transportShuffle
            lastConfirmedShuffleEnabled = transportShuffle
            return
        }
        if transportShuffle == expected {
            shuffleEnabled = transportShuffle
            lastConfirmedShuffleEnabled = transportShuffle
            clearPendingShuffle()
            return
        }
        if let deadline = pendingShuffleDeadline, clock.now < deadline {
            return
        }
        shuffleEnabled = transportShuffle
        lastConfirmedShuffleEnabled = transportShuffle
        clearPendingShuffle()
    }

    /// Applies repeat from Spotify transport while suppressing stale reads
    /// during a short optimistic-repeat window.
    private func applyTransportRepeatMode(_ transportMode: SpotifyRepeatMode) {
        guard let expected = pendingRepeatMode else {
            repeatMode = transportMode
            confirmedRepeatMode = transportMode
            return
        }
        if transportMode == expected {
            repeatMode = transportMode
            confirmedRepeatMode = transportMode
            clearPendingRepeat()
            return
        }
        if let deadline = pendingRepeatDeadline, clock.now < deadline {
            return
        }
        repeatMode = transportMode
        confirmedRepeatMode = transportMode
        clearPendingRepeat()
    }

    private func scheduleTransportSyncAfterRepeatToggle() {
        repeatSyncTask?.cancel()
        repeatSyncTask = Task { [weak self] in
            guard let delay = self?.postRepeatSyncDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.syncTransportFromSpotify()
        }
    }

    private func scheduleTransportSyncAfterShuffleToggle(minimumMutationVersion: UInt64) {
        shuffleSyncTask?.cancel()
        shuffleSyncTask = Task { [weak self] in
            guard let delay = self?.postShuffleSyncDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.syncTransportFromSpotify(minimumShuffleMutationVersion: minimumMutationVersion)
        }
    }

    private func nextShuffleMutationVersion() -> UInt64 {
        shuffleMutationVersion &+= 1
        return shuffleMutationVersion
    }

    private func noteLocalPlaybackMutation(shouldSyncTransportImmediately: Bool = true) {
        localMutationSettleTicksRemaining = max(localMutationSettleTicksRemaining, 2)
        transportRateLimitedUntil = nil
        guard shouldSyncTransportImmediately else { return }
        Task { @MainActor [weak self] in
            await self?.syncTransportFromSpotify()
        }
    }

    private var shouldRunTransportPolling: Bool {
        guard isAppActive else { return false }
        if localMutationSettleTicksRemaining > 0 { return true }
        guard deviceID != nil else { return false }
        switch connectionState {
        case .playing, .paused, .ready, .transferring:
            return true
        case .disconnected, .connecting, .unavailable, .error:
            return false
        }
    }

    private var isPlaybackActiveForPolling: Bool {
        switch connectionState {
        case .playing:
            return true
        default:
            return latestPlayerSnapshot?.isPlaying == true
        }
    }

    private func currentTransportPollDelay() -> Duration {
        if let rateLimitedUntil = transportRateLimitedUntil {
            if rateLimitedUntil > clock.now {
                return max(rateLimitedUntil - clock.now, .seconds(1))
            }
            transportRateLimitedUntil = nil
            return .seconds(15)
        }
        if localMutationSettleTicksRemaining > 0 {
            return .seconds(1)
        }
        if transportTransientErrorCount > 0 {
            let seconds = min(1 << transportTransientErrorCount, 16)
            return .seconds(seconds)
        }
        if latestPlayerSnapshot == nil {
            return .seconds(20)
        }
        if isPlaybackActiveForPolling {
            return .seconds(2)
        }
        switch connectionState {
        case .paused:
            return .seconds(8)
        case .ready, .transferring:
            return .seconds(20)
        case .playing:
            return .seconds(2)
        case .disconnected, .connecting, .unavailable, .error:
            return .seconds(30)
        }
    }

    private func restartTransportPollingIfNeeded() {
        transportPollTask?.cancel()
        transportPollTask = nil
        guard shouldRunTransportPolling else { return }
        transportPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let delay = await MainActor.run { self.currentTransportPollDelay() }
                try? await Task.sleep(for: delay)
                let shouldPoll = await MainActor.run { self.shouldRunTransportPolling }
                guard shouldPoll else { break }
                await self.syncTransportFromSpotify()
            }
        }
    }

    private func setConnectionState(_ state: PlaybackConnectionState) {
        connectionState = state

        switch state {
        case .playing:
            startProgressTickerIfNeeded()
        case .disconnected, .connecting, .ready, .transferring, .paused, .unavailable, .error:
            stopProgressTicker()
        }
        restartTransportPollingIfNeeded()
    }

    private func startProgressTickerIfNeeded() {
        guard progressTickerTask == nil else {
            return
        }

        lastProgressTickInstant = clock.now
        let intervalNanoseconds = UInt64(max(progressTickInterval, 0.01) * 1_000_000_000)
        progressTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                await self?.tickPlaybackProgress()
            }
        }
    }

    private func stopProgressTicker() {
        progressTickerTask?.cancel()
        progressTickerTask = nil
        lastProgressTickInstant = nil
    }

    private func tickPlaybackProgress() {
        guard case let .playing(nowPlaying) = connectionState else {
            return
        }
        guard nowPlaying.durationMilliseconds > 0 else {
            return
        }

        let currentInstant = clock.now
        let previousInstant = lastProgressTickInstant ?? currentInstant
        lastProgressTickInstant = currentInstant
        let deltaComponents = currentInstant - previousInstant
        let deltaSeconds = Double(deltaComponents.components.seconds)
            + (Double(deltaComponents.components.attoseconds) / 1_000_000_000_000_000_000.0)
        guard deltaSeconds > 0 else {
            return
        }

        let deltaMilliseconds = Int((deltaSeconds * 1_000).rounded())
        guard deltaMilliseconds > 0 else {
            return
        }

        let newPosition = min(
            max(0, nowPlaying.positionMilliseconds + deltaMilliseconds),
            nowPlaying.durationMilliseconds
        )
        guard newPosition != nowPlaying.positionMilliseconds else {
            return
        }

        connectionState = .playing(nowPlaying.with(positionMilliseconds: newPosition))
    }
}

final class WebPlaybackViewCommander: WebPlaybackCommanding {
    private weak var webView: WKWebView?
    /// Set when ``loadHost()`` runs before the `WKWebView` has been installed by
    /// `HiddenPlaybackWebView.makeNSView` (a real race on window reopen). The
    /// load is replayed in ``attach(webView:)`` once the WebView is available so
    /// the SDK host page is guaranteed to load.
    private var hostLoadPending = false

    func attach(webView: WKWebView?) {
        self.webView = webView
        if hostLoadPending, let webView {
            hostLoadPending = false
            webView.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
        }
    }

    func loadHost() {
        guard let webView else {
            hostLoadPending = true
            return
        }
        webView.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
    }

    @MainActor
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any] = [:]) async throws {
        guard let webView else { return }
        let script = try commandScript(command, payload: payload)
        _ = try await webView.evaluateJavaScript(script)
    }

    private func commandScript(_ command: PlaybackBridgeCommand, payload: [String: Any]) throws -> String {
        switch command {
        case .connect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.connect();"
        case .disconnect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.disconnect();"
        case .togglePlay:
            return "window.spotiglassPlayback && window.spotiglassPlayback.togglePlay();"
        case .pause:
            return "window.spotiglassPlayback && window.spotiglassPlayback.pause();"
        case .resume:
            return "window.spotiglassPlayback && window.spotiglassPlayback.resume();"
        case .seek:
            let milliseconds = payload["milliseconds"] as? Int ?? 0
            return "window.spotiglassPlayback && window.spotiglassPlayback.seek(\(milliseconds));"
        case .next:
            return "window.spotiglassPlayback && window.spotiglassPlayback.next();"
        case .previous:
            return "window.spotiglassPlayback && window.spotiglassPlayback.previous();"
        case .playURI:
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return "window.spotiglassPlayback && window.spotiglassPlayback.playURI(\(json).uri);"
        case .setVolume:
            let raw = (payload["volume"] as? NSNumber)?.doubleValue
                ?? (payload["volume"] as? Double)
                ?? (payload["volume"] as? Int).map(Double.init)
                ?? 0.8
            let clamped = min(max(raw, 0), 1)
            let literal = String(format: "%.6f", clamped)
            return "window.spotiglassPlayback && window.spotiglassPlayback.setVolume(\(literal));"
        }
    }
}
