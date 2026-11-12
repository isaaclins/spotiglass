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

    /// Only for checking that something does NOT happen. To wait for something that
    /// must happen, use `wait()`: a busy machine can take longer than any window, and
    /// the per-test time limit already catches a signal that never comes (#503). A test that
    /// must release a hold or name what never came before failing passes `mustHappenTimeout`,
    /// which is no window either.
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

/// Holds the first call that reaches it until `release()`, so a test can act while that call is
/// in flight. Any later call releases it: a build that sends a call the test expects to be dropped
/// then fails its assertions instead of hanging. A held call also ends when its task is cancelled.
final class MockCallHold: @unchecked Sendable {
    /// Fires when the first call reaches the hold.
    let entered = AsyncSignal()
    private let released = AsyncSignal()
    private let lock = NSLock()
    private var callCount = 0

    func release() {
        released.signal()
    }

    func pass() async {
        let isFirst = lock.withLock {
            callCount += 1
            return callCount == 1
        }
        guard isFirst else {
            released.signal()
            return
        }
        entered.signal()
        await released.wait()
    }
}

/// Timeout for an `XCTestExpectation` that must be fulfilled. A busy machine can take far longer
/// than a second or two, so this is no time window: it only sits under the 120 s per-test limit
/// (`make test`, CI) so that a fulfilment that never comes fails with the expectation's own
/// description instead of a bare timeout (#503).
let mustHappenTimeout: TimeInterval = 100

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
    // Playback calls run on background tasks while tests read and set this
    // mock on the main thread, so every mutable field lives in `state` behind
    // `stateLock`, like `actions` in `actionRecorder`.
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
        var onPlay: ((String) async -> Void)?
        var onNext: (() async -> Void)?
        var onSeek: ((Int) async -> Void)?
        var onSeekAttempt: ((Int) async -> Void)?
        var activeConnectDevice: MusicPlaybackDevice?
        var availableDevices: [MusicPlaybackDevice] = []
        var onFetchPlayerSnapshot: (() async -> Void)?
        var onFetchAvailableDevices: (() async -> Void)?
        var fetchAvailableDevicesHold: MockCallHold?
        var fetchPlayerSnapshotHold: MockCallHold?
        var setShuffleError: Error?
        var onSetShuffle: ((Bool) async -> Void)?
        var setRepeatError: Error?
        var fetchPlayerSnapshotError: Error?
        var seekError: Error?
        var nextError: Error?
        var pauseError: Error?
        var setRepeatHold: MockCallHold?
        var setShuffleHold: MockCallHold?
        var onTransferPlayback: ((String, Bool) async -> Void)?
        var onTransferPlaybackCompleted: ((String, Bool) async -> Void)?
        var queueResponse = MusicPlaybackQueue(queue: [])
        var onFetchQueue: (() async -> Void)?
    }

    private let actionRecorder = MockPlaybackActionRecorder()
    private let stateLock = NSLock()
    private var state = State()
    var actions: [String] { actionRecorder.snapshot() }
    var lastPlayedURIQueue: [String]? { locked { $0.lastPlayedURIQueue } }
    var lastPlayedOffsetURI: String? { locked { $0.lastPlayedOffsetURI } }
    /// Runs at the top of every `play*` call, with the
    /// URI / context URI / first list URI. Suspending here keeps that play in flight
    /// from the view model's perspective until the closure returns.
    var onPlay: ((String) async -> Void)? {
        get { locked { $0.onPlay } }
        set { locked { $0.onPlay = newValue } }
    }
    var onNext: (() async -> Void)? {
        get { locked { $0.onNext } }
        set { locked { $0.onNext = newValue } }
    }
    var onSeek: ((Int) async -> Void)? {
        get { locked { $0.onSeek } }
        set { locked { $0.onSeek = newValue } }
    }
    var onSeekAttempt: ((Int) async -> Void)? {
        get { locked { $0.onSeekAttempt } }
        set { locked { $0.onSeekAttempt = newValue } }
    }
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
    var activeConnectDevice: MusicPlaybackDevice? {
        get { locked { $0.activeConnectDevice } }
        set { locked { $0.activeConnectDevice = newValue } }
    }
    var availableDevices: [MusicPlaybackDevice] {
        get { locked { $0.availableDevices } }
        set { locked { $0.availableDevices = newValue } }
    }
    var onFetchPlayerSnapshot: (() async -> Void)? {
        get { locked { $0.onFetchPlayerSnapshot } }
        set { locked { $0.onFetchPlayerSnapshot = newValue } }
    }
    var onFetchAvailableDevices: (() async -> Void)? {
        get { locked { $0.onFetchAvailableDevices } }
        set { locked { $0.onFetchAvailableDevices = newValue } }
    }
    /// Holds `fetchAvailableDevices` after it is recorded and `onFetchAvailableDevices` ran.
    var fetchAvailableDevicesHold: MockCallHold? {
        get { locked { $0.fetchAvailableDevicesHold } }
        set { locked { $0.fetchAvailableDevicesHold = newValue } }
    }
    /// Holds `fetchPlayerSnapshot` after it is recorded and `onFetchPlayerSnapshot` ran.
    var fetchPlayerSnapshotHold: MockCallHold? {
        get { locked { $0.fetchPlayerSnapshotHold } }
        set { locked { $0.fetchPlayerSnapshotHold = newValue } }
    }
    var setShuffleError: Error? {
        get { locked { $0.setShuffleError } }
        set { locked { $0.setShuffleError = newValue } }
    }
    var onSetShuffle: ((Bool) async -> Void)? {
        get { locked { $0.onSetShuffle } }
        set { locked { $0.onSetShuffle = newValue } }
    }
    var setRepeatError: Error? {
        get { locked { $0.setRepeatError } }
        set { locked { $0.setRepeatError = newValue } }
    }
    var fetchPlayerSnapshotError: Error? {
        get { locked { $0.fetchPlayerSnapshotError } }
        set { locked { $0.fetchPlayerSnapshotError = newValue } }
    }
    var playErrors: [Error] {
        get { locked { $0.playErrors } }
        set { locked { $0.playErrors = newValue } }
    }
    var seekError: Error? {
        get { locked { $0.seekError } }
        set { locked { $0.seekError = newValue } }
    }
    var nextError: Error? {
        get { locked { $0.nextError } }
        set { locked { $0.nextError = newValue } }
    }
    var pauseError: Error? {
        get { locked { $0.pauseError } }
        set { locked { $0.pauseError = newValue } }
    }
    /// Holds `setRepeat` before it is recorded.
    var setRepeatHold: MockCallHold? {
        get { locked { $0.setRepeatHold } }
        set { locked { $0.setRepeatHold = newValue } }
    }
    /// Holds `setShuffle` after `onSetShuffle` ran, before it is recorded.
    var setShuffleHold: MockCallHold? {
        get { locked { $0.setShuffleHold } }
        set { locked { $0.setShuffleHold = newValue } }
    }
    /// Runs at the top of `transferPlayback`. Tests can use it
    /// to hold a PUT in flight without relying on wall-clock timing.
    var onTransferPlayback: ((String, Bool) async -> Void)? {
        get { locked { $0.onTransferPlayback } }
        set { locked { $0.onTransferPlayback = newValue } }
    }
    /// Runs after a successful transfer is recorded, so tests can await completion
    /// without relying on a wall-clock delay.
    var onTransferPlaybackCompleted: ((String, Bool) async -> Void)? {
        get { locked { $0.onTransferPlaybackCompleted } }
        set { locked { $0.onTransferPlaybackCompleted = newValue } }
    }
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
        if let next = locked({ $0.transferPlaybackErrors.isEmpty ? nil : $0.transferPlaybackErrors.removeFirst() }) {
            actionRecorder.append("transfer-error:\(deviceID):\(play)")
            throw next
        }
        actionRecorder.append("transfer:\(deviceID):\(play)")
        await onTransferPlaybackCompleted?(deviceID, play)
    }

    func play(uri: String, deviceID: String) async throws {
        await onPlay?(uri)
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        await onPlay?(contextURI)
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play-context:\(deviceID):\(contextURI)")
    }

    func pause(deviceID: String) async throws {
        if let pauseError {
            throw pauseError
        }
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
        if let error = nextPlayError() {
            throw error
        }
        actionRecorder.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        locked { $0.seekCallTimestamps.append(Date()) }
        await onSeekAttempt?(milliseconds)
        try Task.checkCancellation()
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

    var queueResponse: MusicPlaybackQueue {
        get { locked { $0.queueResponse } }
        set { locked { $0.queueResponse = newValue } }
    }
    var addToQueueErrors: [Error] {
        get { locked { $0.addToQueueErrors } }
        set { locked { $0.addToQueueErrors = newValue } }
    }
    var onFetchQueue: (() async -> Void)? {
        get { locked { $0.onFetchQueue } }
        set { locked { $0.onFetchQueue = newValue } }
    }

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
        await fetchPlayerSnapshotHold?.pass()
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
        await fetchAvailableDevicesHold?.pass()
        return availableDevices
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        await onSetShuffle?(enabled)
        if let setShuffleError { throw setShuffleError }
        await setShuffleHold?.pass()
        actionRecorder.append("setShuffle:\(deviceID):\(enabled)")
        locked { $0.reportedTransport = MusicPlaybackTransport(shuffle: enabled, repeatMode: $0.reportedTransport.repeatMode) }
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        await setRepeatHold?.pass()
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
