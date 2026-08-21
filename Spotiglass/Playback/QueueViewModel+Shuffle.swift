import Foundation

extension QueueViewModel {
    /// Toggles Spotify shuffle for this device, then reloads the queue so **Up next** reorders with existing list animations.
    func toggleShuffle() async {
        guard playbackSession.isTransportMutationReady else { return }
        let previousUpcoming = upcomingItems
        let previousSnapshot = preShuffleUpcomingSnapshot
        let previousShuffle = playbackSession.shuffleEnabled
        let targetShuffle = !previousShuffle

        if targetShuffle {
            preShuffleUpcomingSnapshot = previousUpcoming
            optimisticUpcomingItems = Self.shuffledDeterministically(previousUpcoming)
            optimisticReconcileTargetIDs = optimisticUpcomingItems?.map(\.id)
            optimisticReconcileDeadline = self.clock.now.advanced(by: optimisticReconcileTimeout)
        } else if let snapshot = preShuffleUpcomingSnapshot {
            optimisticUpcomingItems = snapshot
            preShuffleUpcomingSnapshot = nil
            optimisticReconcileTargetIDs = snapshot.map(\.id)
            optimisticReconcileDeadline = self.clock.now.advanced(by: optimisticReconcileTimeout)
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
}
