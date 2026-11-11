import Foundation
@testable import Spotiglass

/// A ``PlaybackClock`` that only moves when the test moves it. A timer on it fires when the test
/// advances past its deadline, however busy the machine is, and the test can wait until a timer
/// is armed (``waitForSleepers(_:)``) instead of hoping a fixed wait was long enough.
final class ManualPlaybackClock: PlaybackClock, @unchecked Sendable {
    private typealias Sleeper = (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)

    private let lock = NSLock()
    private var current = ContinuousClock().now
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepersWaiters: [(isMet: ([ContinuousClock.Instant]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Timers armed on this clock and not yet fired or cancelled.
    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if current >= deadline {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = (deadline, continuation)
                let ready = takeReadySleepersWaiters()
                lock.unlock()
                ready.forEach { $0.resume() }
            }
        }, onCancel: {
            self.cancel(id)
        })
    }

    /// Moves the clock on and fires every timer that is due by then.
    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.value.deadline <= current }
        due.keys.forEach { sleepers.removeValue(forKey: $0) }
        lock.unlock()
        due.values.forEach { $0.continuation.resume() }
    }

    /// Returns once at least `count` timers are armed on this clock.
    func waitForSleepers(_ count: Int = 1) async {
        await waitUntil { $0.count >= count }
    }

    /// Returns once a timer is armed to fire at `deadline`: a task that sleeps again from the
    /// clock's current time has gone back to waiting.
    func waitForSleeper(dueAt deadline: ContinuousClock.Instant) async {
        await waitUntil { $0.contains(deadline) }
    }

    private func waitUntil(_ isMet: @escaping ([ContinuousClock.Instant]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isMet(sleepers.values.map(\.deadline)) {
                lock.unlock()
                continuation.resume()
                return
            }
            sleepersWaiters.append((isMet, continuation))
            lock.unlock()
        }
    }

    /// Callers hold `lock`.
    private func takeReadySleepersWaiters() -> [CheckedContinuation<Void, Never>] {
        let deadlines = sleepers.values.map(\.deadline)
        var ready: [CheckedContinuation<Void, Never>] = []
        sleepersWaiters.removeAll { waiter in
            guard waiter.isMet(deadlines) else { return false }
            ready.append(waiter.continuation)
            return true
        }
        return ready
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = sleepers.removeValue(forKey: id)?.continuation
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
