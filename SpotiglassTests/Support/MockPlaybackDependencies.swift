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

    private let stateLock = NSLock()
    private var didLoadHostStorage = false
    private var loadHostCallCountStorage = 0
    private var loadedHostGenerationsStorage: [PlaybackHostGeneration] = []
    private var commandsStorage: [SentCommand] = []
    private var currentHostGeneration: PlaybackHostGeneration?

    var didLoadHost: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didLoadHostStorage
    }

    var loadHostCallCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadHostCallCountStorage
    }

    var loadedHostGenerations: [PlaybackHostGeneration] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadedHostGenerationsStorage
    }

    var commands: [SentCommand] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return commandsStorage
    }

    /// Runs after each command is recorded — lets tests await a specific command
    /// deterministically instead of sleeping for "long enough".
    var onSend: ((PlaybackBridgeCommand) async -> Void)?
    var onSendWithPayload: ((PlaybackBridgeCommand, [String: Any]) async -> Void)?
    var onGenerationSend: ((PlaybackBridgeCommand, PlaybackHostGeneration) async -> Void)?
    var onLoadHost: ((PlaybackHostGeneration) -> Void)?

    func loadHost(generation: PlaybackHostGeneration) {
        stateLock.lock()
        didLoadHostStorage = true
        loadHostCallCountStorage += 1
        loadedHostGenerationsStorage.append(generation)
        currentHostGeneration = generation
        stateLock.unlock()
        onLoadHost?(generation)
    }

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {
        record(command: command, payload: payload)
        await onSendWithPayload?(command, payload)
        await onSend?(command)
    }

    func send(
        _ command: PlaybackBridgeCommand,
        payload: [String: Any],
        generation: PlaybackHostGeneration
    ) async throws {
        await onGenerationSend?(command, generation)
        guard !Task.isCancelled, owns(generation: generation) else { return }
        try await send(command, payload: payload)
    }

    private func record(command: PlaybackBridgeCommand, payload: [String: Any]) {
        stateLock.lock()
        commandsStorage.append(SentCommand(command: command, payload: payload))
        stateLock.unlock()
    }

    private func owns(generation: PlaybackHostGeneration) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentHostGeneration == nil || currentHostGeneration == generation
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
    // Playback calls run on background tasks while tests read on the main
    // thread, so the call logs and the response queues this mock drains live
    // in `state` behind `stateLock`, like `actions` in `actionRecorder`.
    private struct State {
        var lastPlayedURIQueue: [String]?
        var lastPlayedOffsetURI: String?
        var seekCallTimestamps: [Date] = []
        var reportedTransport = MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        var transportResponses: [MusicPlaybackTransport?] = []
        var snapshotResponses: [MusicPlaybackSnapshot?] = []
        var playErrors: [Error] = []
        var transferPlaybackErrors: [Error] = []
        var addToQueueErrors: [Error] = []
    }

    private let actionRecorder = MockPlaybackActionRecorder()
    private let stateLock = NSLock()
    private var state = State()
    var actions: [String] { actionRecorder.snapshot() }
    var lastPlayedURIQueue: [String]? { locked { $0.lastPlayedURIQueue } }
    var lastPlayedOffsetURI: String? { locked { $0.lastPlayedOffsetURI } }
    /// Runs at the top of every `play*` call (before the artificial delay), with the
    /// URI / context URI / first list URI. Suspending here keeps that play in flight
    /// from the view model's perspective until the closure returns.
    var onPlay: ((String) async -> Void)?
    var onNext: (() async -> Void)?
    var onSeek: ((Int) async -> Void)?
    var onSeekAttempt: ((Int) async -> Void)?
    var seekCallTimestamps: [Date] { locked { $0.seekCallTimestamps } }
    /// `state.reportedTransport` is returned by `fetchPlayerSnapshot`; updated when mock `setShuffle` / `setRepeat` succeed so background sync matches optimistic UI.
    private let reportedIsPlaying = true
    /// Optional transport snapshots returned before `reportedTransport`; useful for simulating stale reads.
    var transportResponses: [MusicPlaybackTransport?] {
        get { locked { $0.transportResponses } }
        set { locked { $0.transportResponses = newValue } }
    }
    /// Optional full player snapshots (supersedes `reportedTransport` / `activeConnectDevice` when non-empty).
    var snapshotResponses: [MusicPlaybackSnapshot?] {
        get { locked { $0.snapshotResponses } }
        set { locked { $0.snapshotResponses = newValue } }
    }
    var activeConnectDevice: MusicPlaybackDevice?
    var availableDevices: [MusicPlaybackDevice] = []
    var onFetchPlayerSnapshot: (() async -> Void)?
    var onFetchAvailableDevices: (() async -> Void)?
    var fetchAvailableDevicesDelayNanoseconds: UInt64 = 0
    var fetchPlayerSnapshotDelayNanoseconds: UInt64 = 0
    var setShuffleError: Error?
    var onSetShuffle: ((Bool) async -> Void)?
    var setRepeatError: Error?
    var fetchPlayerSnapshotError: Error?
    var playDelayNanoseconds: UInt64 = 0
    var playErrors: [Error] {
        get { locked { $0.playErrors } }
        set { locked { $0.playErrors = newValue } }
    }
    var seekDelayNanoseconds: UInt64 = 0
    var seekError: Error?
    var nextError: Error?
    var setRepeatDelayNanoseconds: UInt64 = 0
    var setShuffleDelayNanoseconds: UInt64 = 0
    /// Runs at the top of `transferPlayback`, before any optional delay. Tests can use it
    /// to hold a PUT in flight without relying on wall-clock timing.
    var onTransferPlayback: ((String, Bool) async -> Void)?
    /// Runs after a successful transfer is recorded, so tests can await completion
    /// without relying on a wall-clock delay.
    var onTransferPlaybackCompleted: ((String, Bool) async -> Void)?
    /// When non-zero, `transferPlayback` sleeps before recording the action. Lets the transfer-playback audit
    /// concurrency tests overlap the in-flight PUT with a sibling caller so the single-flight guard runs.
    var transferPlaybackDelayNanoseconds: UInt64 = 0
    /// FIFO of errors thrown by `transferPlayback`. Empty queue means transfers succeed.
    var transferPlaybackErrors: [Error] {
        get { locked { $0.transferPlaybackErrors } }
        set { locked { $0.transferPlaybackErrors = newValue } }
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    private func nextPlayError() -> Error? {
        locked { $0.playErrors.isEmpty ? nil : $0.playErrors.removeFirst() }
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        await onTransferPlayback?(deviceID, play)
        if transferPlaybackDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: transferPlaybackDelayNanoseconds)
        }
        if let next = locked({ $0.transferPlaybackErrors.isEmpty ? nil : $0.transferPlaybackErrors.removeFirst() }) {
            actionRecorder.append("transfer-error:\(deviceID):\(play)")
            throw next
        }
        actionRecorder.append("transfer:\(deviceID):\(play)")
        await onTransferPlaybackCompleted?(deviceID, play)
    }

    func play(uri: String, deviceID: String) async throws {
        await onPlay?(uri)
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        await onPlay?(contextURI)
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play-context:\(deviceID):\(contextURI)")
    }

    func pause(deviceID: String) async throws {
        actionRecorder.append("pause:\(deviceID)")
    }

    func resume(deviceID: String) async throws {
        actionRecorder.append("resume:\(deviceID)")
    }

    func play(uris: [String], deviceID: String) async throws {
        try await playQueue(uris: uris, offsetURI: nil, deviceID: deviceID)
    }

    func play(uris: [String], offsetURI: String, deviceID: String) async throws {
        try await playQueue(uris: uris, offsetURI: offsetURI, deviceID: deviceID)
    }

    private func playQueue(uris: [String], offsetURI: String?, deviceID: String) async throws {
        locked {
            $0.lastPlayedURIQueue = uris
            $0.lastPlayedOffsetURI = offsetURI
        }
        await onPlay?(offsetURI ?? uris.first ?? "")
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        locked { $0.seekCallTimestamps.append(Date()) }
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

    var queueResponse = MusicPlaybackQueue(queue: [])
    var addToQueueErrors: [Error] {
        get { locked { $0.addToQueueErrors } }
        set { locked { $0.addToQueueErrors = newValue } }
    }
    var onFetchQueue: (() async -> Void)?

    func fetchQueue() async throws -> MusicPlaybackQueue {
        actionRecorder.append("fetchQueue")
        await onFetchQueue?()
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actionRecorder.append("addToQueue:\(deviceID):\(uri)")
        if let error = locked({ $0.addToQueueErrors.isEmpty ? nil : $0.addToQueueErrors.removeFirst() }) {
            throw error
        }
    }

    func fetchPlayerSnapshot() async throws -> MusicPlaybackSnapshot? {
        actionRecorder.append("fetchPlayerSnapshot")
        await onFetchPlayerSnapshot?()
        if fetchPlayerSnapshotDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchPlayerSnapshotDelayNanoseconds)
        }
        if let fetchPlayerSnapshotError {
            throw fetchPlayerSnapshotError
        }
        enum Next {
            case snapshot(MusicPlaybackSnapshot?)
            case transport(MusicPlaybackTransport?)
        }
        let next = locked { state -> Next in
            if !state.snapshotResponses.isEmpty {
                return .snapshot(state.snapshotResponses.removeFirst())
            }
            if !state.transportResponses.isEmpty {
                return .transport(state.transportResponses.removeFirst())
            }
            return .transport(state.reportedTransport)
        }
        switch next {
        case .snapshot(let snapshot):
            return snapshot
        case .transport(let transport):
            guard let transport else { return nil }
            return MusicPlaybackSnapshot(transport: transport, activeDevice: activeConnectDevice, isPlaying: reportedIsPlaying)
        }
    }

    func fetchAvailableDevices() async throws -> [MusicPlaybackDevice] {
        actionRecorder.append("fetchAvailableDevices")
        await onFetchAvailableDevices?()
        if fetchAvailableDevicesDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchAvailableDevicesDelayNanoseconds)
        }
        return availableDevices
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        await onSetShuffle?(enabled)
        if let setShuffleError { throw setShuffleError }
        if setShuffleDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setShuffleDelayNanoseconds)
        }
        actionRecorder.append("setShuffle:\(deviceID):\(enabled)")
        locked { $0.reportedTransport = MusicPlaybackTransport(shuffle: enabled, repeatMode: $0.reportedTransport.repeatMode) }
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        if setRepeatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setRepeatDelayNanoseconds)
        }
        if let setRepeatError { throw setRepeatError }
        actionRecorder.append("setRepeat:\(deviceID):\(mode.rawValue)")
        locked { $0.reportedTransport = MusicPlaybackTransport(shuffle: $0.reportedTransport.shuffle, repeatMode: mode) }
    }
}

extension SpotifyPlaybackProvider {
    /// Spotify provider over a mock Web API, for tests that never touch the SDK page.
    convenience init(playbackAPI: SpotifyPlaybackControlling) {
        self.init(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
    }
}
