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
    private(set) var commands: [SentCommand] = []

    func loadHost() {
        didLoadHost = true
        loadHostCallCount += 1
    }

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {
        commands.append(SentCommand(command: command, payload: payload))
    }
}

final class MockPlaybackAPI: SpotifyPlaybackControlling {
    private(set) var actions: [String] = []
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
    var fetchAvailableDevicesDelayNanoseconds: UInt64 = 0
    var setShuffleError: Error?
    var setRepeatError: Error?
    var playDelayNanoseconds: UInt64 = 0
    var seekDelayNanoseconds: UInt64 = 0
    var setRepeatDelayNanoseconds: UInt64 = 0
    var setShuffleDelayNanoseconds: UInt64 = 0
    /// When non-zero, `transferPlayback` sleeps before recording the action. Lets the transfer-playback audit
    /// concurrency tests overlap the in-flight PUT with a sibling caller so the single-flight guard runs.
    var transferPlaybackDelayNanoseconds: UInt64 = 0
    /// FIFO of errors thrown by `transferPlayback`. Empty queue means transfers succeed.
    var transferPlaybackErrors: [Error] = []

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        if transferPlaybackDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: transferPlaybackDelayNanoseconds)
        }
        if !transferPlaybackErrors.isEmpty {
            let next = transferPlaybackErrors.removeFirst()
            actions.append("transfer-error:\(deviceID):\(play)")
            throw next
        }
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        seekCallTimestamps.append(Date())
        if seekDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: seekDelayNanoseconds)
        }
        actions.append("seek:\(deviceID):\(milliseconds)")
    }

    func next(deviceID: String) async throws {
        actions.append("next:\(deviceID)")
    }

    func previous(deviceID: String) async throws {
        actions.append("previous:\(deviceID)")
    }

    var queueResponse = SpotifyQueueResponse(queue: [])

    func fetchQueue() async throws -> SpotifyQueueResponse {
        actions.append("fetchQueue")
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actions.append("addToQueue:\(deviceID):\(uri)")
    }

    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot? {
        actions.append("fetchPlayerSnapshot")
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
        actions.append("fetchAvailableDevices")
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
        actions.append("setShuffle:\(deviceID):\(enabled)")
        reportedTransport = SpotifyPlayerTransport(shuffle: enabled, repeatMode: reportedTransport.repeatMode)
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if setRepeatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setRepeatDelayNanoseconds)
        }
        if let setRepeatError { throw setRepeatError }
        actions.append("setRepeat:\(deviceID):\(mode.rawValue)")
        reportedTransport = SpotifyPlayerTransport(shuffle: reportedTransport.shuffle, repeatMode: mode)
    }
}
