import Foundation

struct QueueEnqueueResult: Equatable {
    let requested: Int
    let enqueued: Int
}

@MainActor
final class QueueViewModel: ObservableObject {
    @Published var nowPlayingItem: QueueItem?
    @Published var upcomingItems: [QueueItem] = []
    @Published var isLoading = false
    @Published var lastError: BrowsingDisplayError?

    let playbackAPI: SpotifyPlaybackControlling
    let playbackSession: PlaybackSessionViewModel
    var lastFetchedQueue: SpotifyQueueResponse?
    /// Immediate queue projection used while waiting for Spotify queue
    /// reconciliation (e.g. optimistic shuffle UX).
    var optimisticUpcomingItems: [QueueItem]?
    /// Snapshot captured when turning shuffle ON so turning it OFF can restore
    /// the pre-shuffle order instantly.
    var preShuffleUpcomingSnapshot: [QueueItem]?
    /// Target optimistic order awaiting Spotify queue reconciliation.
    var optimisticReconcileTargetIDs: [String]?
    var optimisticReconcileDeadline: ContinuousClock.Instant?
    let optimisticReconcileTimeout: Duration
    let clock = ContinuousClock()
    var pollTask: Task<Void, Never>?
    var isPanelVisible = false
    var isAppActive = true
    var inFlightEnqueueKeys: Set<EnqueueKey> = []
    var enqueueSuccessCooldownUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    var enqueueUnknownOutcomeUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    var enqueueRateLimitUntil: [EnqueueKey: ContinuousClock.Instant] = [:]
    var enqueueRetryTasks: [EnqueueKey: Task<Void, Never>] = [:]

    let pollIntervalNanoseconds: UInt64
    let pausedPollIntervalNanoseconds: UInt64
    let reconnectingPollIntervalNanoseconds: UInt64
    let maxPollIntervalNanoseconds: UInt64
    let stalePollBackoffThreshold: Int
    let pollJitterFraction: Double
    let jitterSource: () -> Double
    let defaultRateLimitCooldownSeconds: TimeInterval
    let maxRateLimitCooldownSeconds: TimeInterval
    let maxUpcomingItems = 20
    let enqueueSuccessCooldown: Duration
    let enqueueUnknownOutcomeCooldown: Duration
    let enqueueMinimumRetryDelay: Duration
    var isRefreshInFlight = false
    var pendingRefreshRequested = false
    var pendingRefreshAllowsHiddenPanel = false
    var unchangedPollTickCount = 0
    var queueCooldownUntil: Date?
    var lastQueuePollingKey: String?
    var queueSessionGeneration: UInt64 = 0
    var queueSessionBoundaryActive = false

    var isQueueSessionBoundary: Bool {
        switch playbackSession.connectionState {
        case .disconnected, .unavailable:
            return true
        case .connecting, .ready, .transferring, .playing, .paused, .error:
            return false
        }
    }

    func clearQueueSessionProjection() {
        if !queueSessionBoundaryActive {
            queueSessionGeneration &+= 1
            queueSessionBoundaryActive = true
        }
        lastFetchedQueue = nil
        optimisticUpcomingItems = nil
        preShuffleUpcomingSnapshot = nil
        optimisticReconcileTargetIDs = nil
        optimisticReconcileDeadline = nil
        nowPlayingItem = nil
        upcomingItems = []
    }

    enum RefreshTrigger {
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

    func item(forSelectionID id: QueueItem.ID) -> QueueItem? {
        upcomingItems.first(where: { $0.id == id })
            ?? nowPlayingItem.flatMap { $0.id == id ? $0 : nil }
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
}

extension QueueItem {
    var durationLabel: String {
        PlaybackNowPlaying.durationText(milliseconds: durationMilliseconds)
    }
}
