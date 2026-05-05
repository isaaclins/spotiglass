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

    private let playbackAPI: SpotifyPlaybackControlling
    private let webCommander: WebPlaybackCommanding
    private let progressTickInterval: TimeInterval
    private let clock = ContinuousClock()
    private let pendingShuffleTimeout: Duration
    private let pendingRepeatTimeout: Duration
    private let postShuffleSyncDelay: Duration
    private let postRepeatSyncDelay: Duration
    private var progressTickerTask: Task<Void, Never>?
    private var shuffleSyncTask: Task<Void, Never>?
    private var repeatSyncTask: Task<Void, Never>?
    private var lastProgressTickInstant: ContinuousClock.Instant?
    private var hasTransferredPlaybackToCurrentDevice = false
    /// Expected repeat mode after an optimistic local toggle. While pending,
    /// stale transport reads from Spotify are ignored for a short window so the
    /// button does not snap back.
    private var pendingRepeatMode: SpotifyRepeatMode?
    private var pendingRepeatDeadline: ContinuousClock.Instant?
    /// Expected shuffle state after an optimistic local toggle. Stale transport
    /// reads are ignored while this short-lived expectation is pending.
    private var pendingShuffleEnabled: Bool?
    private var pendingShuffleDeadline: ContinuousClock.Instant?

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

    private static let playbackVolumeUserDefaultsKey = "spotiglass.playbackVolume"
    /// Matches the default passed to `Spotify.Player({ volume: … })` in the embedded host HTML.
    static let defaultPlaybackVolume: Double = 0.8

    init(
        playbackAPI: SpotifyPlaybackControlling,
        webCommander: WebPlaybackCommanding,
        progressTickInterval: TimeInterval = 0.25,
        pendingShuffleTimeout: Duration = .seconds(2),
        pendingRepeatTimeout: Duration = .seconds(2),
        postShuffleSyncDelay: Duration = .milliseconds(350),
        postRepeatSyncDelay: Duration = .milliseconds(350)
    ) {
        self.playbackAPI = playbackAPI
        self.webCommander = webCommander
        self.progressTickInterval = progressTickInterval
        self.pendingShuffleTimeout = pendingShuffleTimeout
        self.pendingRepeatTimeout = pendingRepeatTimeout
        self.postShuffleSyncDelay = postShuffleSyncDelay
        self.postRepeatSyncDelay = postRepeatSyncDelay
        self.playbackVolume = Self.loadStoredPlaybackVolume()
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
        progressTickerTask?.cancel()
        shuffleSyncTask?.cancel()
        repeatSyncTask?.cancel()
    }

    func start() {
        switch connectionState {
        case .disconnected, .error, .unavailable:
            break
        case .connecting, .ready, .transferring, .playing, .paused:
            return
        }
        hasTransferredPlaybackToCurrentDevice = false
        setConnectionState(.connecting)
        deviceID = nil
        webCommander.loadHost()
        Task {
            try? await webCommander.send(.connect, payload: [:])
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
            Task {
                await syncPlaybackVolumeToWebPlayer()
            }
        case let .notReady(deviceID):
            if self.deviceID == deviceID {
                self.deviceID = nil
            }
            hasTransferredPlaybackToCurrentDevice = false
            sdkNextTracks = []
            setConnectionState(.unavailable("Spotify playback device is no longer available. Reconnect playback to continue."))
        case let .stateChanged(nowPlaying, isPaused, nextTracks):
            if shouldSuppressStaleStateChange(nowPlaying: nowPlaying) {
                return
            }
            sdkNextTracks = nextTracks
            if nowPlaying != nil {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(isPaused ? .paused(nowPlaying) : .playing(nowPlaying ?? fallbackNowPlaying()))
        case let .initializationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Playback could not start", message: message, recoveryAction: .reconnect)))
        case let .authenticationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Sign in again", message: message, recoveryAction: .reauthenticate)))
        case let .accountError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Spotify Premium required", message: message, recoveryAction: nil)))
        case let .playbackError(message):
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
        beginPendingPlay(uri: uri)

        do {
            try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
            try await playbackAPI.play(uri: uri, deviceID: deviceID)
            if let optimisticNowPlaying = optimisticNowPlaying(for: uri) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": uri])
        } catch {
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
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

        do {
            try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
            try await playbackAPI.play(contextURI: contextURI, deviceID: deviceID)
            try await webCommander.send(.playURI, payload: ["uri": contextURI])
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
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
        beginPendingPlay(uri: clickedURI)

        do {
            try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
            try await playbackAPI.play(uris: queue, deviceID: deviceID)
            if let optimisticNowPlaying = optimisticNowPlaying(for: clickedURI) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": clickedURI])
        } catch {
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    func togglePlayPause() async {
        do {
            try await webCommander.send(.togglePlay, payload: [:])
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    func previous() async {
        await sendDeviceCommand { deviceID in
            try await playbackAPI.previous(deviceID: deviceID)
        }
    }

    func next() async {
        await sendDeviceCommand { deviceID in
            try await playbackAPI.next(deviceID: deviceID)
        }
    }

    /// Refreshes shuffle/repeat from Spotify (`GET /v1/me/player`). Safe to call when the queue panel polls; ignores failures without changing connection state.
    func syncTransportFromSpotify() async {
        do {
            if let transport = try await playbackAPI.fetchPlayerTransport() {
                applyTransportShuffleEnabled(transport.shuffle)
                applyTransportRepeatMode(transport.repeatMode)
            }
        } catch {
            // Queue poll should not surface transport read failures as playback errors.
        }
    }

    func toggleShuffle() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let previousShuffle = shuffleEnabled
        let target = !shuffleEnabled
        shuffleEnabled = target
        setPendingShuffle(enabled: target)

        do {
            try await playbackAPI.setShuffle(enabled: target, deviceID: deviceID)
            scheduleTransportSyncAfterShuffleToggle()
        } catch {
            clearPendingShuffle()
            if shuffleEnabled == target {
                shuffleEnabled = previousShuffle
            }
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    func cycleRepeat() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let previousMode = repeatMode
        let nextMode = repeatMode.next
        repeatMode = nextMode
        setPendingRepeat(mode: nextMode)

        do {
            try await playbackAPI.setRepeat(mode: nextMode, deviceID: deviceID)
            scheduleTransportSyncAfterRepeatToggle()
        } catch {
            clearPendingRepeat()
            if repeatMode == nextMode {
                repeatMode = previousMode
            }
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    func seek(to milliseconds: Int) async {
        await sendDeviceCommand { deviceID in
            try await playbackAPI.seek(to: milliseconds, deviceID: deviceID)
        }
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
        repeatMode = .off
        clearPendingShuffle()
        clearPendingRepeat()
        clearPendingPlay()
        setConnectionState(.disconnected)
    }

    /// Retries Spotify “transfer playback” to this device after API or transport failures that set `recoveryAction` to `.retryTransfer`.
    /// If no device ID is known, falls back to `start()` (full Web Playback SDK reconnect).
    func retryPlaybackTransfer() async {
        guard let deviceID else {
            start()
            return
        }
        hasTransferredPlaybackToCurrentDevice = false
        do {
            setConnectionState(.transferring(deviceID: deviceID))
            try await playbackAPI.transferPlayback(to: deviceID, play: false)
            hasTransferredPlaybackToCurrentDevice = true
            setConnectionState(.ready(deviceID: deviceID))
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
        PlaybackNowPlaying(name: "Spotify playback", artists: [], albumName: nil, albumArtURL: nil, durationMilliseconds: 0, positionMilliseconds: 0, uri: nil)
    }

    private func ensurePlaybackTransferredIfNeeded(deviceID: String) async throws {
        guard !hasTransferredPlaybackToCurrentDevice else {
            return
        }
        setConnectionState(.transferring(deviceID: deviceID))
        try await playbackAPI.transferPlayback(to: deviceID, play: false)
        hasTransferredPlaybackToCurrentDevice = true
    }

    private func beginPendingPlay(uri: String) {
        pendingPlayURI = uri
        pendingPlayURIDeadline = clock.now.advanced(by: pendingPlayURITimeout)
    }

    private func clearPendingPlay() {
        pendingPlayURI = nil
        pendingPlayURIDeadline = nil
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

    private func setPendingShuffle(enabled: Bool) {
        pendingShuffleEnabled = enabled
        pendingShuffleDeadline = clock.now.advanced(by: pendingShuffleTimeout)
    }

    private func clearPendingShuffle() {
        pendingShuffleEnabled = nil
        pendingShuffleDeadline = nil
    }

    private func clearPendingRepeat() {
        pendingRepeatMode = nil
        pendingRepeatDeadline = nil
    }

    /// Applies shuffle from Spotify transport while suppressing stale reads
    /// during a short optimistic-shuffle window.
    private func applyTransportShuffleEnabled(_ transportShuffle: Bool) {
        guard let expected = pendingShuffleEnabled else {
            shuffleEnabled = transportShuffle
            return
        }
        if transportShuffle == expected {
            shuffleEnabled = transportShuffle
            clearPendingShuffle()
            return
        }
        if let deadline = pendingShuffleDeadline, clock.now < deadline {
            return
        }
        shuffleEnabled = transportShuffle
        clearPendingShuffle()
    }

    /// Applies repeat from Spotify transport while suppressing stale reads
    /// during a short optimistic-repeat window.
    private func applyTransportRepeatMode(_ transportMode: SpotifyRepeatMode) {
        guard let expected = pendingRepeatMode else {
            repeatMode = transportMode
            return
        }
        if transportMode == expected {
            repeatMode = transportMode
            clearPendingRepeat()
            return
        }
        if let deadline = pendingRepeatDeadline, clock.now < deadline {
            return
        }
        repeatMode = transportMode
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

    private func scheduleTransportSyncAfterShuffleToggle() {
        shuffleSyncTask?.cancel()
        shuffleSyncTask = Task { [weak self] in
            guard let delay = self?.postShuffleSyncDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.syncTransportFromSpotify()
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
    weak var webView: WKWebView?

    func loadHost() {
        webView?.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
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
