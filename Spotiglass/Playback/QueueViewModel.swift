import Foundation

@MainActor
final class QueueViewModel: ObservableObject {
    @Published private(set) var nowPlayingItem: QueueItem?
    @Published private(set) var upcomingItems: [QueueItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: BrowsingDisplayError?

    private let playbackAPI: SpotifyPlaybackControlling
    private let playbackSession: PlaybackSessionViewModel
    private var lastFetchedQueue: SpotifyQueueResponse?
    /// Immediate queue projection used while waiting for Spotify queue
    /// reconciliation (e.g. optimistic shuffle UX).
    private var optimisticUpcomingItems: [QueueItem]?
    /// Snapshot captured when turning shuffle ON so turning it OFF can restore
    /// the pre-shuffle order instantly.
    private var preShuffleUpcomingSnapshot: [QueueItem]?
    /// Target optimistic order awaiting Spotify queue reconciliation.
    private var optimisticReconcileTargetIDs: [String]?
    private var optimisticReconcileDeadline: ContinuousClock.Instant?
    private let optimisticReconcileTimeout: Duration
    private let clock = ContinuousClock()
    private var pollTask: Task<Void, Never>?
    private var isPanelVisible = false
    private var isAppActive = true
    private var inFlightEnqueueKeys: Set<EnqueueKey> = []
    private var enqueueSuccessCooldownUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    private var enqueueUnknownOutcomeUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    private var enqueueRateLimitUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    private var enqueueRetryTasks: [EnqueueKey: Task<Void, Never>] = [:]

    private let pollIntervalNanoseconds: UInt64
    private let pausedPollIntervalNanoseconds: UInt64
    private let reconnectingPollIntervalNanoseconds: UInt64
    private let maxPollIntervalNanoseconds: UInt64
    private let stalePollBackoffThreshold: Int
    private let pollJitterFraction: Double
    private let jitterSource: () -> Double
    private let defaultRateLimitCooldownSeconds: TimeInterval
    private let maxRateLimitCooldownSeconds: TimeInterval
    private let maxUpcomingItems = 20
    private let enqueueSuccessCooldown: Duration
    private let enqueueUnknownOutcomeCooldown: Duration
    private let enqueueMinimumRetryDelay: Duration
    private var isRefreshInFlight = false
    private var pendingRefreshRequested = false
    private var pendingRefreshAllowsHiddenPanel = false
    private var unchangedPollTickCount = 0
    private var queueCooldownUntil: Date?
    private var lastQueuePollingKey: String?

    private enum RefreshTrigger {
        case manual
        case poll
        case event
        case lyricsPrefetch
    }

    init(
        playbackAPI: SpotifyPlaybackControlling,
        playbackSession: PlaybackSessionViewModel,
        pollIntervalNanoseconds: UInt64 = 4_000_000_000,
        pausedPollIntervalNanoseconds: UInt64 = 12_000_000_000,
        reconnectingPollIntervalNanoseconds: UInt64 = 15_000_000_000,
        maxPollIntervalNanoseconds: UInt64 = 20_000_000_000,
        stalePollBackoffThreshold: Int = 5,
        pollJitterFraction: Double = 0.10,
        jitterSource: @escaping () -> Double = { Double.random(in: -1...1) },
        defaultRateLimitCooldownSeconds: TimeInterval = 8,
        maxRateLimitCooldownSeconds: TimeInterval = 30,
        optimisticReconcileTimeout: Duration = .seconds(3),
        enqueueSuccessCooldown: Duration = .seconds(2),
        enqueueUnknownOutcomeCooldown: Duration = .seconds(5),
        enqueueMinimumRetryDelay: Duration = .seconds(1)
    ) {
        self.playbackAPI = playbackAPI
        self.playbackSession = playbackSession
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.pausedPollIntervalNanoseconds = pausedPollIntervalNanoseconds
        self.reconnectingPollIntervalNanoseconds = reconnectingPollIntervalNanoseconds
        self.maxPollIntervalNanoseconds = maxPollIntervalNanoseconds
        self.stalePollBackoffThreshold = stalePollBackoffThreshold
        self.pollJitterFraction = max(0, min(0.5, pollJitterFraction))
        self.jitterSource = jitterSource
        self.defaultRateLimitCooldownSeconds = defaultRateLimitCooldownSeconds
        self.maxRateLimitCooldownSeconds = maxRateLimitCooldownSeconds
        self.optimisticReconcileTimeout = optimisticReconcileTimeout
        self.enqueueSuccessCooldown = enqueueSuccessCooldown
        self.enqueueUnknownOutcomeCooldown = enqueueUnknownOutcomeCooldown
        self.enqueueMinimumRetryDelay = enqueueMinimumRetryDelay
    }

    var isPlaybackPlaying: Bool {
        if case .playing = playbackSession.connectionState { return true }
        return false
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if visible {
            Task { @MainActor [weak self] in
                await self?.requestQueueRefresh(trigger: .event, allowsHiddenPanel: false)
            }
            restartPollingIfNeeded()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive
        if isActive {
            if isPanelVisible {
                Task { await requestQueueRefresh(trigger: .event, allowsHiddenPanel: false) }
            }
            restartPollingIfNeeded()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func syncFromPlaybackSession() {
        publishMergedState()
    }

    /// Web Playback SDK updated `track_window.next_tracks` (e.g. track advanced, queue context changed).
    /// Merges immediately and refetches the REST queue so the panel matches Spotify without waiting for the poll interval.
    func handleSdkQueueSnapshotChanged() {
        publishMergedState()
        guard isPanelVisible else { return }
        switch playbackSession.connectionState {
        case .playing, .paused:
            Task { @MainActor [weak self] in
                await self?.requestQueueRefresh(trigger: .event, allowsHiddenPanel: false)
            }
            restartPollingIfNeeded()
        default:
            break
        }
    }

    func handlePlaybackStateChange() {
        publishMergedState()
        let pollingKey = queuePollingKey(for: playbackSession.connectionState)
        let pollingKeyChanged = pollingKey != lastQueuePollingKey
        lastQueuePollingKey = pollingKey
        switch playbackSession.connectionState {
        case .playing, .paused:
            if isPanelVisible {
                Task { @MainActor [weak self] in
                    await self?.requestQueueRefresh(trigger: .event, allowsHiddenPanel: false)
                }
                if pollingKeyChanged {
                    restartPollingIfNeeded()
                }
            }
        default:
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refreshQueue() async {
        await requestQueueRefresh(trigger: .manual, allowsHiddenPanel: false)
    }

    private func requestQueueRefresh(trigger: RefreshTrigger, allowsHiddenPanel: Bool) async {
        publishMergedState()
        guard shouldAllowQueueRequest(allowsHiddenPanel: allowsHiddenPanel) else { return }
        if isRefreshInFlight {
            pendingRefreshRequested = true
            pendingRefreshAllowsHiddenPanel = pendingRefreshAllowsHiddenPanel || allowsHiddenPanel
            return
        }

        var nextAllowsHiddenPanel = allowsHiddenPanel
        while true {
            guard shouldAllowQueueRequest(allowsHiddenPanel: nextAllowsHiddenPanel) else { break }
            if let cooldownUntil = queueCooldownUntil, cooldownUntil > Date() {
                lastError = Self.rateLimitDisplayError(retryAfter: cooldownUntil.timeIntervalSinceNow)
                pendingRefreshRequested = false
                pendingRefreshAllowsHiddenPanel = false
                break
            }

            isRefreshInFlight = true
            isLoading = true
            var queueChanged = false
            do {
                let fetchedQueue = try await playbackAPI.fetchQueue()
                queueChanged = lastFetchedQueue != fetchedQueue
                lastFetchedQueue = fetchedQueue
                lastError = nil
                queueCooldownUntil = nil
            } catch {
                if let apiError = error as? SpotifyAPIError,
                   case let .rateLimited(retryAfter) = apiError {
                    let fallback = max(1, min(defaultRateLimitCooldownSeconds, maxRateLimitCooldownSeconds))
                    let effectiveRetry = min(max(retryAfter ?? fallback, 1), maxRateLimitCooldownSeconds)
                    queueCooldownUntil = Date().addingTimeInterval(effectiveRetry)
                }
                // A queue refresh that is superseded by a newer one (e.g. the
                // poll task is restarted because the user paused/unpaused) shows
                // up here as a CancellationError or URLError.cancelled. Those
                // are not real failures from the user's perspective, so don't
                // surface them as a "Queue update failed" banner.
                if let mapped = Self.displayError(for: error) {
                    lastError = mapped
                }
            }
            isLoading = false
            isRefreshInFlight = false
            clearOptimisticProjectionIfReconciled()
            publishMergedState()

            if trigger == .poll {
                unchangedPollTickCount = queueChanged ? 0 : (unchangedPollTickCount + 1)
            } else {
                unchangedPollTickCount = 0
            }

            guard pendingRefreshRequested else { break }
            nextAllowsHiddenPanel = pendingRefreshAllowsHiddenPanel
            pendingRefreshRequested = false
            pendingRefreshAllowsHiddenPanel = false
        }
    }

    func playItem(_ item: QueueItem) async {
        guard let uri = item.uri else { return }
        await playbackSession.play(uri: uri)
    }

    func addToQueue(uri: String) async {
        guard let deviceID = playbackSession.deviceID else {
            lastError = BrowsingDisplayError(
                title: "Playback unavailable",
                message: "Connect Spotiglass playback before adding to the queue.",
                canRetry: false
            )
            return
        }
        await performAddToQueue(uri: uri, deviceID: deviceID, source: .user)
    }

    private func performAddToQueue(uri: String, deviceID: String, source: EnqueueSource) async {
        let key = EnqueueKey(uri: uri, deviceID: deviceID)
        clearExpiredEnqueueGuards()
        if inFlightEnqueueKeys.contains(key) {
            lastError = BrowsingDisplayError(
                title: "Already adding to queue",
                message: "That track is already being added.",
                canRetry: false
            )
            return
        }
        if let blockedUntil = enqueueSuccessCooldownUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: "Already queued",
                message: "That track was queued just now.",
                canRetry: false
            )
            return
        }
        if let blockedUntil = enqueueUnknownOutcomeUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: "Queue status pending",
                message: "Queue status is still being confirmed. Try again in a moment.",
                canRetry: true
            )
            return
        }
        if let blockedUntil = enqueueRateLimitUntil[key], blockedUntil > clock.now {
            let remaining = clock.now.duration(to: blockedUntil).timeInterval
            let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: remaining)
            lastError = BrowsingDisplayError(
                title: "Rate limited",
                message: "Spotify is rate limiting requests. \(clause)",
                canRetry: true,
                diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: remaining)
            )
            return
        }

        inFlightEnqueueKeys.insert(key)
        do {
            try await playbackAPI.addToQueue(uri: uri, deviceID: deviceID)
            lastError = nil
            enqueueSuccessCooldownUntil[key] = clock.now.advanced(by: enqueueSuccessCooldown)
            enqueueUnknownOutcomeUntil.removeValue(forKey: key)
            enqueueRateLimitUntil.removeValue(forKey: key)
            await refreshQueue()
        } catch {
            if let apiError = error as? SpotifyAPIError,
               case let .rateLimited(retryAfter) = apiError {
                let retryDelay = Self.retryDelay(
                    retryAfter: retryAfter,
                    minimumDelay: enqueueMinimumRetryDelay.timeInterval
                )
                enqueueRateLimitUntil[key] = clock.now.advanced(by: .seconds(retryDelay))
                if source == .user {
                    scheduleRateLimitedRetry(for: key, retryDelay: retryDelay)
                }
            } else if Self.isAmbiguousTransportError(error) {
                enqueueUnknownOutcomeUntil[key] = clock.now.advanced(by: enqueueUnknownOutcomeCooldown)
            }
            if let mapped = Self.displayError(for: error) {
                lastError = mapped
            }
        }
        inFlightEnqueueKeys.remove(key)
    }

    func clearError() {
        lastError = nil
    }

    private func scheduleRateLimitedRetry(for key: EnqueueKey, retryDelay: TimeInterval) {
        guard enqueueRetryTasks[key] == nil else { return }
        enqueueRetryTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(retryDelay, 0) * 1_000_000_000))
            } catch {
                await MainActor.run { self?.enqueueRetryTasks.removeValue(forKey: key) }
                return
            }
            await MainActor.run {
                self?.enqueueRetryTasks.removeValue(forKey: key)
            }
            guard !Task.isCancelled else { return }
            await self?.performAddToQueue(uri: key.uri, deviceID: key.deviceID, source: .autoRetry)
        }
    }

    private func clearExpiredEnqueueGuards() {
        let now = clock.now
        enqueueSuccessCooldownUntil = enqueueSuccessCooldownUntil.filter { $0.value > now }
        enqueueUnknownOutcomeUntil = enqueueUnknownOutcomeUntil.filter { $0.value > now }
        enqueueRateLimitUntil = enqueueRateLimitUntil.filter { $0.value > now }
    }

    /// Refetches the Spotify queue for auxiliary UI (lyrics “next up”) even when the queue panel is closed.
    /// Failures are silent so the strip still shows SDK `next_tracks` via ``publishMergedState``.
    func prefetchQueueForLyricsOverlay() async {
        await requestQueueRefresh(trigger: .lyricsPrefetch, allowsHiddenPanel: true)
    }

    /// Toggles Spotify shuffle for this device, then reloads the queue so **Up next** reorders with existing list animations.
    func toggleShuffle() async {
        let previousUpcoming = upcomingItems
        let previousSnapshot = preShuffleUpcomingSnapshot
        let previousShuffle = playbackSession.shuffleEnabled
        let targetShuffle = !previousShuffle

        if targetShuffle {
            preShuffleUpcomingSnapshot = previousUpcoming
            optimisticUpcomingItems = Self.shuffledDeterministically(previousUpcoming)
            optimisticReconcileTargetIDs = optimisticUpcomingItems?.map(\.id)
            optimisticReconcileDeadline = clock.now.advanced(by: optimisticReconcileTimeout)
        } else if let snapshot = preShuffleUpcomingSnapshot {
            optimisticUpcomingItems = snapshot
            preShuffleUpcomingSnapshot = nil
            optimisticReconcileTargetIDs = snapshot.map(\.id)
            optimisticReconcileDeadline = clock.now.advanced(by: optimisticReconcileTimeout)
        }
        publishMergedState()

        await playbackSession.toggleShuffle()
        if playbackSession.shuffleEnabled != targetShuffle {
            optimisticUpcomingItems = previousUpcoming
            preShuffleUpcomingSnapshot = previousSnapshot
            optimisticReconcileTargetIDs = nil
            optimisticReconcileDeadline = nil
            publishMergedState()
        }
        await refreshQueue()
    }

    private func restartPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = nil
        guard isPanelVisible else { return }
        guard isAppActive else { return }
        guard shouldPoll else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    try await Task.sleep(nanoseconds: self.nextPollIntervalNanoseconds())
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard self.isPanelVisible, self.isAppActive, self.shouldPoll else { break }
                await self.requestQueueRefresh(trigger: .poll, allowsHiddenPanel: false)
            }
        }
    }

    private func queuePollingKey(for state: PlaybackConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case let .ready(deviceID):
            "ready:\(deviceID)"
        case let .transferring(deviceID):
            "transferring:\(deviceID)"
        case let .playing(item):
            "playing:\(item.uri ?? "")"
        case let .paused(.some(item)):
            "paused:\(item.uri ?? "")"
        case .paused(.none):
            "paused-empty"
        case let .unavailable(message):
            "unavailable:\(message)"
        case let .error(error):
            "error:\(error.title)"
        }
    }

    private var shouldPoll: Bool {
        switch playbackSession.connectionState {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    private func shouldAllowQueueRequest(allowsHiddenPanel: Bool) -> Bool {
        guard isAppActive else { return false }
        if allowsHiddenPanel {
            return shouldPoll
        }
        return isPanelVisible
    }

    private func nextPollIntervalNanoseconds() -> UInt64 {
        var base = basePollIntervalNanoseconds()
        if unchangedPollTickCount >= stalePollBackoffThreshold {
            let backoffStep = unchangedPollTickCount - stalePollBackoffThreshold + 1
            let multiplier = pow(1.5, Double(backoffStep))
            base = UInt64(min(Double(maxPollIntervalNanoseconds), Double(base) * multiplier))
        }
        if let cooldownUntil = queueCooldownUntil, cooldownUntil > Date() {
            let cooldownNanoseconds = UInt64(max(0, cooldownUntil.timeIntervalSinceNow) * 1_000_000_000)
            base = max(base, cooldownNanoseconds)
        }
        guard pollJitterFraction > 0 else { return base }
        let jitterScalar = max(-1, min(1, jitterSource()))
        let multiplier = 1 + (jitterScalar * pollJitterFraction)
        let jittered = max(1, Double(base) * multiplier)
        return UInt64(min(Double(UInt64.max), jittered))
    }

    private func basePollIntervalNanoseconds() -> UInt64 {
        switch playbackSession.connectionState {
        case .playing:
            return pollIntervalNanoseconds
        case .paused:
            return pausedPollIntervalNanoseconds
        case .connecting, .transferring:
            return reconnectingPollIntervalNanoseconds
        case .disconnected, .ready, .unavailable, .error:
            return maxPollIntervalNanoseconds
        }
    }

    private func publishMergedState() {
        nowPlayingItem = Self.nowPlayingQueueItem(from: playbackSession.connectionState)
        let nowPlayingURI = nowPlayingItem?.uri
        let sdkNext = playbackSession.sdkNextTracks
        let rawUpcoming: [QueueItem]
        if let optimisticUpcomingItems {
            rawUpcoming = Self.removingDuplicateNowPlaying(from: optimisticUpcomingItems, nowPlayingURI: nowPlayingURI)
        } else if let api = lastFetchedQueue {
            let merged = Self.mergedUpcoming(apiResponse: api, sdkNext: sdkNext, limit: maxUpcomingItems)
            let deduped = Self.removingDuplicateNowPlaying(from: merged, nowPlayingURI: nowPlayingURI)
            if Self.shouldPreferSDKProjection(apiUpcoming: deduped, sdkNext: sdkNext, nowPlayingURI: nowPlayingURI) {
                rawUpcoming = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
            } else {
                rawUpcoming = deduped
            }
        } else {
            rawUpcoming = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
        }
        upcomingItems = Self.applyRepeatOneGate(rawUpcoming, repeatMode: playbackSession.repeatMode)
    }

    /// Keeps optimistic queue visible until Spotify queue confirms the target
    /// order, or until a small timeout elapses.
    private func clearOptimisticProjectionIfReconciled() {
        guard optimisticUpcomingItems != nil else { return }
        if playbackSession.repeatMode == .track {
            optimisticUpcomingItems = nil
            optimisticReconcileTargetIDs = nil
            optimisticReconcileDeadline = nil
            return
        }
        guard let targetIDs = optimisticReconcileTargetIDs else {
            optimisticUpcomingItems = nil
            return
        }
        let nowPlayingURI = nowPlayingItem?.uri
        let sdkNext = playbackSession.sdkNextTracks
        let candidateRaw: [QueueItem]
        if let api = lastFetchedQueue {
            let merged = Self.mergedUpcoming(apiResponse: api, sdkNext: sdkNext, limit: maxUpcomingItems)
            let deduped = Self.removingDuplicateNowPlaying(from: merged, nowPlayingURI: nowPlayingURI)
            if Self.shouldPreferSDKProjection(apiUpcoming: deduped, sdkNext: sdkNext, nowPlayingURI: nowPlayingURI) {
                candidateRaw = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
            } else {
                candidateRaw = deduped
            }
        } else {
            candidateRaw = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
        }
        let candidate = Self.applyRepeatOneGate(candidateRaw, repeatMode: playbackSession.repeatMode)
        if candidate.map(\.id) == targetIDs {
            optimisticUpcomingItems = nil
            optimisticReconcileTargetIDs = nil
            optimisticReconcileDeadline = nil
            return
        }
        if let deadline = optimisticReconcileDeadline, clock.now >= deadline {
            optimisticUpcomingItems = nil
            optimisticReconcileTargetIDs = nil
            optimisticReconcileDeadline = nil
        }
    }

    /// Spotify’s queue and Web Playback `next_tracks` still list contextual “next”
    /// items while repeat-one is active; playback loops the current track instead.
    private static func applyRepeatOneGate(_ items: [QueueItem], repeatMode: SpotifyRepeatMode) -> [QueueItem] {
        repeatMode == .track ? [] : items
    }

    private static func sdkUpcomingItems(from sdkNext: [PlaybackNowPlaying], limit: Int) -> [QueueItem] {
        Array(sdkNext.map { QueueItem.from(playback: $0) }.prefix(limit))
    }

    private static func nowPlayingQueueItem(from state: PlaybackConnectionState) -> QueueItem? {
        let np: PlaybackNowPlaying?
        switch state {
        case let .playing(item):
            np = item
        case let .paused(item):
            np = item
        default:
            np = nil
        }
        guard let np else { return nil }
        return QueueItem.from(playback: np)
    }

    private static func mergedUpcoming(apiResponse: SpotifyQueueResponse, sdkNext: [PlaybackNowPlaying], limit: Int) -> [QueueItem] {
        let apiQueue = apiResponse.queue
        guard !apiQueue.isEmpty else {
            return Array(sdkNext.map { QueueItem.from(playback: $0) }.prefix(limit))
        }
        var result: [QueueItem] = []
        for item in apiQueue where result.count < limit {
            result.append(QueueItem.from(queueItem: item))
        }
        return result
    }

    /// During skip/track-advance transitions, API queue snapshots can lag
    /// behind SDK `next_tracks`; prefer SDK ordering when the heads diverge or
    /// when API still includes now-playing as "up next".
    private static func shouldPreferSDKProjection(
        apiUpcoming: [QueueItem],
        sdkNext: [PlaybackNowPlaying],
        nowPlayingURI: String?
    ) -> Bool {
        guard !sdkNext.isEmpty else { return false }
        if apiUpcoming.isEmpty { return true }
        let apiFirst = apiUpcoming.first?.uri
        let sdkFirst = sdkNext.first?.uri
        if apiFirst != sdkFirst {
            return true
        }
        if let nowPlayingURI, apiUpcoming.contains(where: { $0.uri == nowPlayingURI }) {
            return true
        }
        return false
    }

    private static func removingDuplicateNowPlaying(from items: [QueueItem], nowPlayingURI: String?) -> [QueueItem] {
        guard let nowPlayingURI else { return items }
        return items.filter { $0.uri != nowPlayingURI }
    }

    private static func shuffledDeterministically(_ items: [QueueItem]) -> [QueueItem] {
        guard items.count > 1 else { return items }
        var output = items
        let seedBasis = items.map(\.id).joined(separator: "|")
        var seed = UInt64(bitPattern: Int64(seedBasis.hashValue))
        for idx in stride(from: output.count - 1, through: 1, by: -1) {
            seed = 6364136223846793005 &* seed &+ 1442695040888963407
            let swapIndex = Int(seed % UInt64(idx + 1))
            if idx != swapIndex {
                output.swapAt(idx, swapIndex)
            }
        }
        if output.map(\.id) == items.map(\.id) {
            var rotated = output
            let first = rotated.removeFirst()
            rotated.append(first)
            return rotated
        }
        return output
    }

    /// Maps an underlying error to a user-visible banner, or returns nil for
    /// silent classes of error (cancellation from a superseded refresh).
    private static func displayError(for error: Error) -> BrowsingDisplayError? {
        if error is CancellationError {
            return nil
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return nil
        }
        if let apiError = error as? SpotifyAPIError {
            if case let .network(message) = apiError, message.contains("cancelled") {
                return nil
            }
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(title: "Sign in again", message: "Spotify rejected the access token.", canRetry: false)
            case let .forbidden(message, _):
                return BrowsingDisplayError(title: "Could not load queue", message: message ?? "Spotify denied access.", canRetry: false)
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: "Rate limited",
                    message: "Spotify is rate limiting requests. \(clause)",
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            default:
                return BrowsingDisplayError(title: "Queue update failed", message: "\(apiError)", canRetry: true)
            }
        }
        return BrowsingDisplayError(title: "Queue update failed", message: error.localizedDescription, canRetry: true)
    }

    private static func isAmbiguousTransportError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        if let apiError = error as? SpotifyAPIError {
            if case .network = apiError { return true }
        }
        return false
    }

    private static func retryDelay(retryAfter: TimeInterval?, minimumDelay: TimeInterval) -> TimeInterval {
        let base = max(retryAfter ?? minimumDelay, minimumDelay)
        return min(base, 10)
    }

    private static func rateLimitDisplayError(retryAfter: TimeInterval) -> BrowsingDisplayError {
        let normalizedRetry = max(0, retryAfter)
        let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: normalizedRetry)
        return BrowsingDisplayError(
            title: "Rate limited",
            message: "Spotify is rate limiting requests. \(clause)",
            canRetry: true,
            diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: normalizedRetry)
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct EnqueueKey: Hashable {
    let uri: String
    let deviceID: String
}

private enum EnqueueSource {
    case user
    case autoRetry
}

extension QueueItem {
    var durationLabel: String {
        PlaybackNowPlaying.durationText(milliseconds: durationMilliseconds)
    }
}
