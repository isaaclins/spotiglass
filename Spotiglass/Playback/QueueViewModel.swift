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

    private let pollIntervalNanoseconds: UInt64
    private let maxUpcomingItems = 20

    init(
        playbackAPI: SpotifyPlaybackControlling,
        playbackSession: PlaybackSessionViewModel,
        pollIntervalNanoseconds: UInt64 = 4_000_000_000,
        optimisticReconcileTimeout: Duration = .seconds(3)
    ) {
        self.playbackAPI = playbackAPI
        self.playbackSession = playbackSession
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.optimisticReconcileTimeout = optimisticReconcileTimeout
    }

    var isPlaybackPlaying: Bool {
        if case .playing = playbackSession.connectionState { return true }
        return false
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if visible {
            Task { await refreshQueue() }
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
            Task { await refreshQueue() }
            restartPollingIfNeeded()
        default:
            break
        }
    }

    func handlePlaybackStateChange() {
        publishMergedState()
        switch playbackSession.connectionState {
        case .playing, .paused:
            if isPanelVisible {
                Task { await refreshQueue() }
                restartPollingIfNeeded()
            }
        default:
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refreshQueue() async {
        publishMergedState()
        guard isPanelVisible else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            lastFetchedQueue = try await playbackAPI.fetchQueue()
            lastError = nil
        } catch {
            // A queue refresh that is superseded by a newer one (e.g. the
            // poll task is restarted because the user paused/unpaused) shows
            // up here as a CancellationError or URLError.cancelled. Those
            // are not real failures from the user's perspective, so don't
            // surface them as a "Queue update failed" banner.
            if let mapped = Self.displayError(for: error) {
                lastError = mapped
            }
        }
        await playbackSession.syncTransportFromSpotify()
        clearOptimisticProjectionIfReconciled()
        publishMergedState()
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
        do {
            try await playbackAPI.addToQueue(uri: uri, deviceID: deviceID)
            lastError = nil
            await refreshQueue()
        } catch {
            if let mapped = Self.displayError(for: error) {
                lastError = mapped
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Refetches the Spotify queue for auxiliary UI (lyrics “next up”) even when the queue panel is closed.
    /// Failures are silent so the strip still shows SDK `next_tracks` via ``publishMergedState``.
    func prefetchQueueForLyricsOverlay() async {
        publishMergedState()
        guard shouldPoll else { return }
        do {
            lastFetchedQueue = try await playbackAPI.fetchQueue()
            lastError = nil
        } catch {
            // Best-effort: merged state falls back to Web Playback `sdkNextTracks`.
        }
        await playbackSession.syncTransportFromSpotify()
        publishMergedState()
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
        guard shouldPoll else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                guard self.isPanelVisible, self.shouldPoll else { break }
                await self.refreshQueueAfterPollTick()
            }
        }
    }

    private func refreshQueueAfterPollTick() async {
        publishMergedState()
        guard isPanelVisible else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            lastFetchedQueue = try await playbackAPI.fetchQueue()
            lastError = nil
        } catch {
            if let mapped = Self.displayError(for: error) {
                lastError = mapped
            }
        }
        await playbackSession.syncTransportFromSpotify()
        clearOptimisticProjectionIfReconciled()
        publishMergedState()
    }

    private var shouldPoll: Bool {
        switch playbackSession.connectionState {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    private func publishMergedState() {
        nowPlayingItem = Self.nowPlayingQueueItem(from: playbackSession.connectionState)
        let nowPlayingURI = nowPlayingItem?.uri
        let sdkNext = playbackSession.sdkNextTracks
        if let optimisticUpcomingItems {
            upcomingItems = Self.removingDuplicateNowPlaying(from: optimisticUpcomingItems, nowPlayingURI: nowPlayingURI)
            return
        }
        if let api = lastFetchedQueue {
            let merged = Self.mergedUpcoming(apiResponse: api, sdkNext: sdkNext, limit: maxUpcomingItems)
            let deduped = Self.removingDuplicateNowPlaying(from: merged, nowPlayingURI: nowPlayingURI)
            if Self.shouldPreferSDKProjection(apiUpcoming: deduped, sdkNext: sdkNext, nowPlayingURI: nowPlayingURI) {
                upcomingItems = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
            } else {
                upcomingItems = deduped
            }
        } else {
            upcomingItems = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
        }
    }

    /// Keeps optimistic queue visible until Spotify queue confirms the target
    /// order, or until a small timeout elapses.
    private func clearOptimisticProjectionIfReconciled() {
        guard optimisticUpcomingItems != nil else { return }
        guard let targetIDs = optimisticReconcileTargetIDs else {
            optimisticUpcomingItems = nil
            return
        }
        let nowPlayingURI = nowPlayingItem?.uri
        let sdkNext = playbackSession.sdkNextTracks
        let candidate: [QueueItem]
        if let api = lastFetchedQueue {
            let merged = Self.mergedUpcoming(apiResponse: api, sdkNext: sdkNext, limit: maxUpcomingItems)
            let deduped = Self.removingDuplicateNowPlaying(from: merged, nowPlayingURI: nowPlayingURI)
            if Self.shouldPreferSDKProjection(apiUpcoming: deduped, sdkNext: sdkNext, nowPlayingURI: nowPlayingURI) {
                candidate = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
            } else {
                candidate = deduped
            }
        } else {
            candidate = Self.sdkUpcomingItems(from: sdkNext, limit: maxUpcomingItems)
        }
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

    private static func sdkUpcomingItems(from sdkNext: [PlaybackNowPlaying], limit: Int) -> [QueueItem] {
        Array(sdkNext.map { QueueItem.from(playback: $0, source: .sdk) }.prefix(limit))
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
        return QueueItem.from(playback: np, source: .upcoming)
    }

    private static func mergedUpcoming(apiResponse: SpotifyQueueResponse, sdkNext: [PlaybackNowPlaying], limit: Int) -> [QueueItem] {
        let apiQueue = apiResponse.queue
        guard !apiQueue.isEmpty else {
            return Array(sdkNext.map { QueueItem.from(playback: $0, source: .sdk) }.prefix(limit))
        }
        var result: [QueueItem] = []
        for (index, item) in apiQueue.enumerated() where result.count < limit {
            let source = sourceForMerge(index: index, item: item, sdkNext: sdkNext)
            result.append(QueueItem.from(queueItem: item, source: source))
        }
        return result
    }

    private static func sourceForMerge(index: Int, item: SpotifyQueueTrackItem, sdkNext: [PlaybackNowPlaying]) -> QueueItemSource {
        if index < sdkNext.count, let sdkURI = sdkNext[index].uri {
            let itemURI = uriString(for: item)
            return itemURI == sdkURI ? .sdk : .upcoming
        }
        return index >= sdkNext.count ? .userQueued : .upcoming
    }

    private static func uriString(for item: SpotifyQueueTrackItem) -> String {
        switch item {
        case let .track(t): t.uri
        case let .episode(e): e.uri
        }
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
}

extension QueueItem {
    var durationLabel: String {
        PlaybackNowPlaying.durationText(milliseconds: durationMilliseconds)
    }
}
