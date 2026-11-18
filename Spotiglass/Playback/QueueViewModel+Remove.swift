import Foundation

/// Taking songs out of the queue and putting them back (#628). Only services whose player can
/// edit its queue offer it (``MusicPlaybackProvider/queueEditing``): Spotify's Web API has no
/// endpoint that removes a queued song.
extension QueueViewModel {
    var canEditQueue: Bool { provider.queueEditing != nil }

    /// The upcoming rows among `ids`, as removals: each row's place in the list and its URI.
    /// The playing row is not upcoming, so it is never among them.
    func removals(for ids: Set<QueueItem.ID>) -> [QueueRemoval] {
        upcomingItems.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { QueueRemoval(position: $0.offset, uri: $0.element.uri) }
    }

    /// Takes the selected upcoming rows out of the queue. The rows leave the list at once; the
    /// queue is read again once the player has them out.
    @discardableResult
    func removeItems(withIDs ids: Set<QueueItem.ID>) async -> QueueRemovalReceipt? {
        let removals = removals(for: ids)
        guard let editing = provider.queueEditing, !removals.isEmpty else { return nil }
        let positions = Set(removals.map(\.position))
        let seen = QueueSnapshot(current: nowPlayingItem?.uri, upcoming: upcomingItems.map(\.uri))
        return await applyRemoval(hiding: { $0.enumerated().filter { !positions.contains($0.offset) }.map(\.element) }) {
            try await editing.removeFromQueue(removals, seen: seen)
        }
    }

    /// Takes out everything after the current song.
    @discardableResult
    func clearUpcoming() async -> QueueRemovalReceipt? {
        guard let editing = provider.queueEditing, !upcomingItems.isEmpty else { return nil }
        return await applyRemoval(hiding: { _ in [] }) {
            try await editing.clearUpcomingQueue()
        }
    }

    /// Puts a removal's songs back where they were.
    func undoRemoval(_ receipt: QueueRemovalReceipt) async {
        guard let editing = provider.queueEditing else { return }
        if lastRemoval?.id == receipt.id { lastRemoval = nil }
        do {
            try await editing.restoreToQueue(receipt)
            autoplay.listenerRestored(receipt.tracks)
            lastError = nil
        } catch is CancellationError {
            // The session ended meanwhile: there is no queue to put them back into.
        } catch {
            lastError = Self.displayError(for: error, service: provider.service)
        }
        await queueEdited()
    }

    func dismissRemovalNotice() {
        lastRemoval = nil
    }

    private func applyRemoval(
        hiding hide: ([MusicPlaybackItem]) -> [MusicPlaybackItem],
        _ remove: () async throws -> QueueRemovalReceipt
    ) async -> QueueRemovalReceipt? {
        if let fetched = lastFetchedQueue {
            lastFetchedQueue = MusicPlaybackQueue(queue: hide(fetched.queue))
            publishMergedState()
        }
        do {
            let receipt = try await remove()
            // Autoplay must not bring a song the listener took out straight back.
            autoplay.listenerRemoved(receipt.tracks)
            lastError = nil
            lastRemoval = receipt.count > 0 ? receipt : nil
            await queueEdited()
            return receipt.count > 0 ? receipt : nil
        } catch is CancellationError {
            await queueEdited()
            return nil
        } catch {
            lastError = Self.displayError(for: error, service: provider.service)
            await queueEdited()
            return nil
        }
    }

    /// Every window's queue panel reads the queue again, this one included.
    private func queueEdited() async {
        autoplay.queueChanged.send()
        await requestQueueRefresh(trigger: .event, allowsHiddenPanel: true)
    }
}
