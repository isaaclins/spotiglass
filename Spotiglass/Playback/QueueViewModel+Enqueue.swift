import Foundation

extension QueueViewModel {
    func playItem(_ item: QueueItem) async {
        guard let uri = item.uri else { return }
        await playbackSession.play(uri: uri)
    }

    func addToQueue(uri: String) async {
        guard let deviceID = playbackSession.deviceID else {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.playbackUnavailable.title"),
                message: SpotiglassL10n.string("error.queue.playbackUnavailable.message"),
                canRetry: false
            )
            return
        }
        await performAddToQueue(uri: uri, deviceID: deviceID, source: .user)
    }

    func clearError() {
        lastError = nil
    }

    func performAddToQueue(uri: String, deviceID: String, source: EnqueueSource) async {
        let key = EnqueueKey(uri: uri, deviceID: deviceID)
        clearExpiredEnqueueGuards()
        if inFlightEnqueueKeys.contains(key) {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.alreadyAdding.title"),
                message: SpotiglassL10n.string("error.queue.alreadyAdding.message"),
                canRetry: false
            )
            return
        }
        if let blockedUntil = enqueueSuccessCooldownUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.alreadyQueued.title"),
                message: SpotiglassL10n.string("error.queue.alreadyQueued.message"),
                canRetry: false
            )
            return
        }
        if let blockedUntil = enqueueUnknownOutcomeUntil[key], blockedUntil > clock.now {
            lastError = BrowsingDisplayError(
                title: SpotiglassL10n.string("error.queue.statusPending.title"),
                message: SpotiglassL10n.string("error.queue.statusPending.message"),
                canRetry: true
            )
            return
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
        }
        inFlightEnqueueKeys.remove(key)
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
