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

    /// The music service's player; the queue is read from and added to through it.
    let provider: any MusicPlaybackProvider
    let playbackSession: PlaybackSessionViewModel
    var lastFetchedQueue: MusicPlaybackQueue?
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
    /// Times the optimistic shuffle window and the enqueue cooldowns (a test steps it).
    let clock: any PlaybackClock
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
    /// What the follow-up round runs as: `.poll` unless an event or a manual refresh joined it,
    /// which also runs while the app is in the background.
    var pendingRefreshTrigger: RefreshTrigger = .poll
    /// Callers that asked for a refresh while one was in flight. They resume
    /// once the follow-up round that covers their request has finished.
    var pendingRefreshWaiters: [CheckedContinuation<Void, Never>] = []
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

        /// The timed reads pause while the app is in the background; the others don't (#413).
        var waitsForActiveApp: Bool {
            switch self {
            case .poll, .lyricsPrefetch: true
            case .manual, .event: false
            }
        }
    }

    init(
        provider: any MusicPlaybackProvider,
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
        enqueueMinimumRetryDelay: Duration = .seconds(1),
        clock: any PlaybackClock = ContinuousClock()
    ) {
        self.provider = provider
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
        self.clock = clock
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
