import Foundation

extension QueueViewModel {
    func refreshQueue() async {
        await requestQueueRefresh(trigger: .manual, allowsHiddenPanel: false)
    }

    func requestQueueRefresh(trigger: RefreshTrigger, allowsHiddenPanel: Bool) async {
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
                    case .rateLimited(let retryAfter) = apiError
                {
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

    /// Failures are silent so the strip still shows SDK `next_tracks` via ``publishMergedState``.
    func prefetchQueueForLyricsOverlay() async {
        await requestQueueRefresh(trigger: .lyricsPrefetch, allowsHiddenPanel: true)
    }

    func restartPollingIfNeeded() {
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

    func queuePollingKey(for state: PlaybackConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .ready(let deviceID):
            "ready:\(deviceID)"
        case .transferring(let deviceID):
            "transferring:\(deviceID)"
        case .playing(let item):
            "playing:\(item.uri ?? "")"
        case .paused(.some(let item)):
            "paused:\(item.uri ?? "")"
        case .paused(.none):
            "paused-empty"
        case .unavailable(let message):
            "unavailable:\(message)"
        case .error(let error):
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

    func publishMergedState() {
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
        case .playing(let item):
            np = item
        case .paused(let item):
            np = item
        default:
            np = nil
        }
        guard let np else { return nil }
        return QueueItem.from(playback: np)
    }

    private static func mergedUpcoming(apiResponse: SpotifyQueueResponse, sdkNext: [PlaybackNowPlaying], limit: Int)
        -> [QueueItem]
    {
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

    static func shuffledDeterministically(_ items: [QueueItem]) -> [QueueItem] {
        guard items.count > 1 else { return items }
        var output = items
        let seedBasis = items.map(\.id).joined(separator: "|")
        var seed = UInt64(bitPattern: Int64(seedBasis.hashValue))
        for idx in stride(from: output.count - 1, through: 1, by: -1) {
            seed = 6_364_136_223_846_793_005 &* seed &+ 1_442_695_040_888_963_407
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
    static func displayError(for error: Error) -> BrowsingDisplayError? {
        if error is CancellationError {
            return nil
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return nil
        }
        if let apiError = error as? SpotifyAPIError {
            if case .network(let message) = apiError, message.contains("cancelled") {
                return nil
            }
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.queue.signInAgain.title"),
                    message: SpotiglassL10n.string("error.queue.signInAgain.message"),
                    canRetry: false
                )
            case .forbidden(let message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.queue.loadFailed.title"),
                    message: message ?? SpotiglassL10n.string("error.queue.loadFailed.message"),
                    canRetry: false
                )
            case .rateLimited(let retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.queue.rateLimited.title"),
                    message: String(format: SpotiglassL10n.string("error.queue.rateLimited.message"), clause),
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            default:
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.queue.updateFailed.title"),
                    message: String(
                        format: SpotiglassL10n.string("error.queue.updateFailed.message"), String(describing: apiError)),
                    canRetry: true
                )
            }
        }
        return BrowsingDisplayError(
            title: SpotiglassL10n.string("error.queue.updateFailed.title"),
            message: String(
                format: SpotiglassL10n.string("error.queue.updateFailed.message"), error.localizedDescription),
            canRetry: true
        )
    }

    static func isAmbiguousTransportError(_ error: Error) -> Bool {
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

    static func retryDelay(retryAfter: TimeInterval?, minimumDelay: TimeInterval) -> TimeInterval {
        let base = max(retryAfter ?? minimumDelay, minimumDelay)
        return min(base, 10)
    }

    private static func rateLimitDisplayError(retryAfter: TimeInterval) -> BrowsingDisplayError {
        let normalizedRetry = max(0, retryAfter)
        let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: normalizedRetry)
        return BrowsingDisplayError(
            title: SpotiglassL10n.string("error.queue.rateLimited.title"),
            message: String(format: SpotiglassL10n.string("error.queue.rateLimited.message"), clause),
            canRetry: true,
            diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: normalizedRetry)
        )
    }
}
