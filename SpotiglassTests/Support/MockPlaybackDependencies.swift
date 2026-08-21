import Foundation
@testable import Spotiglass

@MainActor
final class MockPlaybackTokenProvider: PlaybackAccessTokenProviding {
    let accessToken: String
    let refreshedAccessToken: String
    private(set) var refreshCount = 0

    init(accessToken: String, refreshedAccessToken: String) {
        self.accessToken = accessToken
        self.refreshedAccessToken = refreshedAccessToken
    }

    func playbackAccessToken() async throws -> String {
        accessToken
    }

    func refreshedPlaybackAccessToken() async throws -> String {
        refreshCount += 1
        return refreshedAccessToken
    }
}

final class MockWebPlaybackCommander: WebPlaybackCommanding {
    struct SentCommand {
        let command: PlaybackBridgeCommand
        let payload: [String: Any]
    }

    private(set) var didLoadHost = false
    private(set) var loadHostCallCount = 0
    private(set) var loadedHostGenerations: [PlaybackHostGeneration] = []
    private(set) var commands: [SentCommand] = []
    private var currentHostGeneration: PlaybackHostGeneration?
    /// Runs after each command is recorded — lets tests await a specific command
    /// deterministically instead of sleeping for "long enough".
    var onSend: ((PlaybackBridgeCommand) async -> Void)?
    var onGenerationSend: ((PlaybackBridgeCommand, PlaybackHostGeneration) async -> Void)?

    func loadHost(generation: PlaybackHostGeneration) {
        didLoadHost = true
        loadHostCallCount += 1
        loadedHostGenerations.append(generation)
        currentHostGeneration = generation
    }

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {
        commands.append(SentCommand(command: command, payload: payload))
        await onSend?(command)
    }

    func send(
        _ command: PlaybackBridgeCommand,
        payload: [String: Any],
        generation: PlaybackHostGeneration
    ) async throws {
        await onGenerationSend?(command, generation)
        guard !Task.isCancelled,
              currentHostGeneration == nil || currentHostGeneration == generation
        else { return }
        try await send(command, payload: payload)
    }
}

/// One-shot async signal: `wait()` suspends until `signal()`. Signalling with no
/// waiter is remembered, so a later `wait()` returns immediately. Lets tests
/// order overlapping commands deterministically instead of racing wall-clock sleeps.
final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        lock.lock()
        signaled = true
        let resumed = waiters.values
        waiters.removeAll()
        lock.unlock()
        for continuation in resumed { continuation.resume() }
    }

    func wait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if signaled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        }, onCancel: {
            cancelWaiter(waiterID)
        })
    }

    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume()
    }
}

private final class MockPlaybackActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []

    func append(_ action: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedActions.append(action)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedActions
    }
}

final class MockPlaybackAPI: SpotifyPlaybackControlling {
    private let actionRecorder = MockPlaybackActionRecorder()
    var actions: [String] { actionRecorder.snapshot() }
    /// Runs at the top of every `play*` call (before the artificial delay), with the
    /// URI / context URI / first list URI. Suspending here keeps that play in flight
    /// from the view model's perspective until the closure returns.
    var onPlay: ((String) async -> Void)?
    var onNext: (() async -> Void)?
    var onSeek: ((Int) async -> Void)?
    var onSeekAttempt: ((Int) async -> Void)?
    private(set) var seekCallTimestamps: [Date] = []
    /// Returned by `fetchPlayerSnapshot`; updated when mock `setShuffle` / `setRepeat` succeed so background sync matches optimistic UI.
    private var reportedTransport = SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
    private var reportedIsPlaying = true
    /// Optional transport snapshots returned before `reportedTransport`; useful for simulating stale reads.
    var transportResponses: [SpotifyPlayerTransport?] = []
    /// Optional full player snapshots (supersedes `reportedTransport` / `activeConnectDevice` when non-empty).
    var snapshotResponses: [SpotifyPlayerSnapshot?] = []
    var activeConnectDevice: SpotifyConnectDevice?
    var availableDevices: [SpotifyConnectDevice] = []
    var onFetchPlayerSnapshot: (() async -> Void)?
    var onFetchAvailableDevices: (() async -> Void)?
    var fetchAvailableDevicesDelayNanoseconds: UInt64 = 0
    var fetchPlayerSnapshotDelayNanoseconds: UInt64 = 0
    var setShuffleError: Error?
    var setRepeatError: Error?
    var fetchPlayerSnapshotError: Error?
    var playDelayNanoseconds: UInt64 = 0
    var playErrors: [Error] = []
    var seekDelayNanoseconds: UInt64 = 0
    var seekError: Error?
    var nextError: Error?
    var setRepeatDelayNanoseconds: UInt64 = 0
    var setShuffleDelayNanoseconds: UInt64 = 0
    /// Runs at the top of `transferPlayback`, before any optional delay. Tests can use it
    /// to hold a PUT in flight without relying on wall-clock timing.
    var onTransferPlayback: ((String, Bool) async -> Void)?
    /// When non-zero, `transferPlayback` sleeps before recording the action. Lets the transfer-playback audit
    /// concurrency tests overlap the in-flight PUT with a sibling caller so the single-flight guard runs.
    var transferPlaybackDelayNanoseconds: UInt64 = 0
    /// FIFO of errors thrown by `transferPlayback`. Empty queue means transfers succeed.
    var transferPlaybackErrors: [Error] = []

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        await onTransferPlayback?(deviceID, play)
        if transferPlaybackDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: transferPlaybackDelayNanoseconds)
        }
        if !transferPlaybackErrors.isEmpty {
            let next = transferPlaybackErrors.removeFirst()
            actionRecorder.append("transfer-error:\(deviceID):\(play)")
            throw next
        }
        actionRecorder.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        await onPlay?(uri)
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if !playErrors.isEmpty {
            throw playErrors.removeFirst()
        }
        actionRecorder.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        await onPlay?(contextURI)
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if !playErrors.isEmpty {
            throw playErrors.removeFirst()
        }
        actionRecorder.append("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        await onPlay?(uris.first ?? "")
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if !playErrors.isEmpty {
            throw playErrors.removeFirst()
        }
        actionRecorder.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        seekCallTimestamps.append(Date())
        await onSeekAttempt?(milliseconds)
        try Task.checkCancellation()
        if seekDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: seekDelayNanoseconds)
        }
        if let seekError {
            throw seekError
        }
        actionRecorder.append("seek:\(deviceID):\(milliseconds)")
        await onSeek?(milliseconds)
    }

    func next(deviceID: String) async throws {
        await onNext?()
        if let nextError {
            throw nextError
        }
        actionRecorder.append("next:\(deviceID)")
    }

    func previous(deviceID: String) async throws {
        actionRecorder.append("previous:\(deviceID)")
    }

    var queueResponse = SpotifyQueueResponse(queue: [])
    var addToQueueErrors: [Error] = []

    func fetchQueue() async throws -> SpotifyQueueResponse {
        actionRecorder.append("fetchQueue")
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actionRecorder.append("addToQueue:\(deviceID):\(uri)")
        if !addToQueueErrors.isEmpty {
            throw addToQueueErrors.removeFirst()
        }
    }

    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot? {
        actionRecorder.append("fetchPlayerSnapshot")
        await onFetchPlayerSnapshot?()
        if fetchPlayerSnapshotDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchPlayerSnapshotDelayNanoseconds)
        }
        if let fetchPlayerSnapshotError {
            throw fetchPlayerSnapshotError
        }
        if !snapshotResponses.isEmpty {
            return snapshotResponses.removeFirst()
        }
        if !transportResponses.isEmpty {
            let transport = transportResponses.removeFirst()
            guard let transport else { return nil }
            return SpotifyPlayerSnapshot(transport: transport, activeDevice: activeConnectDevice, isPlaying: reportedIsPlaying)
        }
        return SpotifyPlayerSnapshot(transport: reportedTransport, activeDevice: activeConnectDevice, isPlaying: reportedIsPlaying)
    }

    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice] {
        actionRecorder.append("fetchAvailableDevices")
        await onFetchAvailableDevices?()
        if fetchAvailableDevicesDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchAvailableDevicesDelayNanoseconds)
        }
        return availableDevices
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        if setShuffleDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setShuffleDelayNanoseconds)
        }
        actionRecorder.append("setShuffle:\(deviceID):\(enabled)")
        reportedTransport = SpotifyPlayerTransport(shuffle: enabled, repeatMode: reportedTransport.repeatMode)
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if setRepeatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setRepeatDelayNanoseconds)
        }
        if let setRepeatError { throw setRepeatError }
        actionRecorder.append("setRepeat:\(deviceID):\(mode.rawValue)")
        reportedTransport = SpotifyPlayerTransport(shuffle: reportedTransport.shuffle, repeatMode: mode)
    }
}
