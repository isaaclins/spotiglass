import Foundation
@testable import Spotiglass

/// A ``PlaybackClock`` that only moves when the test moves it. A timer on it fires when the test
/// advances past its deadline, however busy the machine is, and the test can wait until a timer
/// is armed (``waitForSleepers(_:timeout:)``) instead of hoping a fixed wait was long enough.
final class ManualPlaybackClock: PlaybackClock, @unchecked Sendable {
    private typealias Sleeper = (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)

    private let lock = NSLock()
    private var current = ContinuousClock().now
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepersWaiters: [UUID: (isMet: ([ContinuousClock.Instant]) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]

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
                ready.forEach { $0.resume(returning: true) }
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

    /// Returns `true` once at least `count` timers are armed on this clock, or `false` if none
    /// came within `timeout` of real time, so a test whose timer never arms fails with its own
    /// message instead of hanging until the test runner's limit. The default is no time window:
    /// a busy machine can take long to arm a timer (#535).
    func waitForSleepers(_ count: Int = 1, timeout: Duration = testWaitDeadline) async -> Bool {
        await waitUntil(timeout: timeout) { $0.count >= count }
    }

    /// Returns `true` once a timer is armed to fire at `deadline` (a task that sleeps again from
    /// the clock's current time has gone back to waiting), or `false` after `timeout`.
    func waitForSleeper(dueAt deadline: ContinuousClock.Instant, timeout: Duration = testWaitDeadline) async -> Bool {
        await waitUntil(timeout: timeout) { $0.contains(deadline) }
    }

    private func waitUntil(timeout: Duration, _ isMet: @escaping ([ContinuousClock.Instant]) -> Bool) async -> Bool {
        let id = UUID()
        let met = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if isMet(sleepers.values.map(\.deadline)) {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            sleepersWaiters[id] = (isMet, continuation)
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.giveUp(id)
            }
        }
        return met
    }

    /// Callers hold `lock`.
    private func takeReadySleepersWaiters() -> [CheckedContinuation<Bool, Never>] {
        let deadlines = sleepers.values.map(\.deadline)
        let ready = sleepersWaiters.filter { $0.value.isMet(deadlines) }
        ready.keys.forEach { sleepersWaiters.removeValue(forKey: $0) }
        return ready.values.map(\.continuation)
    }

    private func giveUp(_ id: UUID) {
        lock.lock()
        let continuation = sleepersWaiters.removeValue(forKey: id)?.continuation
        lock.unlock()
        continuation?.resume(returning: false)
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = sleepers.removeValue(forKey: id)?.continuation
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
