import Foundation

extension QueueViewModel {
    func playItem(_ item: QueueItem) async {
        guard let uri = item.playableURI else { return }
        await playbackSession.play(uri: uri)
    }

    /// Existing single-track callers keep the fire-and-forget API. Batch callers
    /// use the overload below, which serializes Spotify's one-URI endpoint while
    /// preserving the supplied order.
    func addToQueue(uri: String) async {
        guard let deviceID = playbackSession.commandDeviceID else {
            publishPlaybackUnavailableError()
            return
        }
        _ = await performAddToQueue(uri: uri, deviceID: deviceID, source: .user)
    }

    /// Enqueues a continuation in order. A failure stops the batch so a rate
    /// limit or unavailable device cannot turn one user action into a storm of
    /// requests. The result lets the caller report a partial queue honestly.
    @discardableResult
    func addToQueue(uris: [String]) async -> QueueEnqueueResult {
        var uniqueURIs: [String] = []
        var seen: Set<String> = []
        for uri in uris {
            guard let canonical = SpotifyPlayableURI.canonical(uri), seen.insert(canonical).inserted else { continue }
            uniqueURIs.append(canonical)
        }
        guard !uniqueURIs.isEmpty else {
            return QueueEnqueueResult(requested: 0, enqueued: 0)
        }
        guard let deviceID = playbackSession.commandDeviceID else {
            publishPlaybackUnavailableError()
            return QueueEnqueueResult(requested: uniqueURIs.count, enqueued: 0)
        }

        var enqueued = 0
        for uri in uniqueURIs {
            guard !Task.isCancelled else { break }
            let succeeded = await performAddToQueue(
                uri: uri,
                deviceID: deviceID,
                source: .user,
                refreshQueueAfterSuccess: false
            )
            guard succeeded else { break }
            enqueued += 1
        }
        if enqueued > 0 {
            await refreshQueue()
        }
        return QueueEnqueueResult(requested: uniqueURIs.count, enqueued: enqueued)
    }

    func clearError() {
        lastError = nil
    }

    @discardableResult
    func performAddToQueue(
        uri: String,
        deviceID: String,
        source: EnqueueSource,
        refreshQueueAfterSuccess: Bool = true
    ) async -> Bool {
        let key = EnqueueKey(uri: uri, deviceID: deviceID)
        clearExpiredEnqueueGuards()
        if inFlightEnqueueKeys.contains(key) {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.alreadyAdding.title"),
                message: SpotiglassL10n.string("error.queue.alreadyAdding.message"),
                canRetry: false
            )
            return false
        }
        if let blockedUntil = enqueueSuccessCooldownUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.alreadyQueued.title"),
                message: SpotiglassL10n.string("error.queue.alreadyQueued.message"),
                canRetry: false
            )
            return false
        }
        if let blockedUntil = enqueueUnknownOutcomeUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.statusPending.title"),
                message: SpotiglassL10n.string("error.queue.statusPending.message"),
                canRetry: true
            )
            return false
        }
        if let blockedUntil = enqueueRateLimitUntil[key], blockedUntil > clock.now {
            let remaining = clock.now.duration(to: blockedUntil).timeInterval
            let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: remaining)
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.rateLimited.title"),
                message: String(format: SpotiglassL10n.string("error.queue.rateLimited.message"), clause),
                canRetry: true,
                diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: remaining)
            )
            return false
        }

        inFlightEnqueueKeys.insert(key)
        defer { inFlightEnqueueKeys.remove(key) }
        do {
            try await playbackAPI.addToQueue(uri: uri, deviceID: deviceID)
            lastError = nil
            enqueueSuccessCooldownUntil[key] = clock.now.advanced(by: enqueueSuccessCooldown)
            enqueueUnknownOutcomeUntil.removeValue(forKey: key)
            enqueueRateLimitUntil.removeValue(forKey: key)
            if refreshQueueAfterSuccess {
                await refreshQueue()
            }
            return true
        } catch {
            if let apiError = error as? SpotifyAPIError,
                case .rateLimited(let retryAfter) = apiError
            {
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
            return false
        }
    }

    private func publishPlaybackUnavailableError() {
        lastError = BrowsingDisplayError(
            title: SpotiglassL10n.string("error.queue.playbackUnavailable.title"),
            message: SpotiglassL10n.string("error.queue.playbackUnavailable.message"),
            canRetry: false
        )
    }

    private func scheduleRateLimitedRetry(for key: EnqueueKey, retryDelay: TimeInterval) {
        guard enqueueRetryTasks[key] == nil else { return }
        enqueueRetryTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(retryDelay, 0) * 1_000_000_000))
            } catch {
                _ = await MainActor.run { self?.enqueueRetryTasks.removeValue(forKey: key) }
                return
            }
            _ = await MainActor.run {
                self?.enqueueRetryTasks.removeValue(forKey: key)
            }
            guard !Task.isCancelled else { return }
            _ = await self?.performAddToQueue(uri: key.uri, deviceID: key.deviceID, source: .autoRetry)
        }
    }

    private func clearExpiredEnqueueGuards() {
        let now = clock.now
        enqueueSuccessCooldownUntil = enqueueSuccessCooldownUntil.filter { $0.value > now }
        enqueueUnknownOutcomeUntil = enqueueUnknownOutcomeUntil.filter { $0.value > now }
        enqueueRateLimitUntil = enqueueRateLimitUntil.filter { $0.value > now }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

struct EnqueueKey: Hashable {
    let uri: String
    let deviceID: String
}

enum EnqueueSource {
    case user
    case autoRetry
}
