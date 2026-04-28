import Foundation
import WebKit

protocol WebPlaybackCommanding {
    func loadHost()
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws
}

@MainActor
final class PlaybackSessionViewModel: ObservableObject {
    @Published private(set) var connectionState: PlaybackConnectionState = .disconnected
    @Published private(set) var deviceID: String?
    @Published private(set) var latestLog: String?

    private let playbackAPI: SpotifyPlaybackControlling
    private let webCommander: WebPlaybackCommanding

    init(playbackAPI: SpotifyPlaybackControlling, webCommander: WebPlaybackCommanding) {
        self.playbackAPI = playbackAPI
        self.webCommander = webCommander
    }

    func start() {
        switch connectionState {
        case .disconnected, .error, .unavailable:
            break
        case .connecting, .ready, .transferring, .playing, .paused:
            return
        }
        connectionState = .connecting
        deviceID = nil
        webCommander.loadHost()
        Task {
            try? await webCommander.send(.connect, payload: [:])
        }
    }

    func handle(_ event: PlaybackBridgeEvent) {
        switch event {
        case let .ready(deviceID):
            self.deviceID = deviceID
            connectionState = .ready(deviceID: deviceID)
        case let .notReady(deviceID):
            if self.deviceID == deviceID {
                self.deviceID = nil
            }
            connectionState = .unavailable("Spotify playback device is no longer available. Reconnect playback to continue.")
        case let .stateChanged(nowPlaying, isPaused):
            connectionState = isPaused ? .paused(nowPlaying) : .playing(nowPlaying ?? fallbackNowPlaying())
        case let .initializationError(message):
            connectionState = .error(PlaybackDisplayError(title: "Playback could not start", message: message, recoveryAction: .reconnect))
        case let .authenticationError(message):
            connectionState = .error(PlaybackDisplayError(title: "Sign in again", message: message, recoveryAction: .reauthenticate))
        case let .accountError(message):
            connectionState = .error(PlaybackDisplayError(title: "Spotify Premium required", message: message, recoveryAction: nil))
        case let .playbackError(message):
            connectionState = .error(PlaybackDisplayError(title: "Playback error", message: message, recoveryAction: .retryTransfer))
        case let .log(message):
            latestLog = message
        }
    }

    func play(uri: String) async {
        guard let deviceID else {
            connectionState = .error(PlaybackDisplayError(
                title: "Playback device unavailable",
                message: "The Spotify Web Playback SDK has not reported a ready device yet.",
                recoveryAction: .reconnect
            ))
            return
        }

        connectionState = .transferring(deviceID: deviceID)
        do {
            try await playbackAPI.transferPlayback(to: deviceID, play: false)
            try await playbackAPI.play(uri: uri, deviceID: deviceID)
            try await webCommander.send(.playURI, payload: ["uri": uri])
        } catch {
            connectionState = .error(Self.displayError(for: error))
        }
    }

    func togglePlayPause() async {
        do {
            try await webCommander.send(.togglePlay, payload: [:])
        } catch {
            connectionState = .error(Self.displayError(for: error))
        }
    }

    func previous() async {
        await sendDeviceCommand(.previous) { deviceID in
            try await playbackAPI.previous(deviceID: deviceID)
        }
    }

    func next() async {
        await sendDeviceCommand(.next) { deviceID in
            try await playbackAPI.next(deviceID: deviceID)
        }
    }

    func seek(to milliseconds: Int) async {
        await sendDeviceCommand(.seek) { deviceID in
            try await playbackAPI.seek(to: milliseconds, deviceID: deviceID)
        }
    }

    func disconnect() async {
        do {
            try await webCommander.send(.disconnect, payload: [:])
        } catch {
            latestLog = error.localizedDescription
        }
        deviceID = nil
        connectionState = .disconnected
    }

    private func sendDeviceCommand(
        _ command: PlaybackBridgeCommand,
        action: (String) async throws -> Void
    ) async {
        guard let deviceID else {
            connectionState = .error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect))
            return
        }
        do {
            try await action(deviceID)
            try await webCommander.send(command, payload: [:])
        } catch {
            connectionState = .error(Self.displayError(for: error))
        }
    }

    static func displayError(for error: Error) -> PlaybackDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return PlaybackDisplayError(title: "Sign in again", message: "Spotify rejected the access token used for playback.", recoveryAction: .reauthenticate)
            case let .forbidden(message, _):
                return PlaybackDisplayError(title: "Spotify Premium required", message: message ?? "Spotify Web Playback SDK playback requires a Premium account.", recoveryAction: nil)
            case let .rateLimited(retryAfter):
                let suffix = retryAfter.map { " Try again in \(Int($0)) seconds." } ?? ""
                return PlaybackDisplayError(title: "Playback rate limited", message: "Spotify is rate limiting playback commands.\(suffix)", recoveryAction: .retryTransfer)
            default:
                return PlaybackDisplayError(title: "Playback command failed", message: "\(apiError)", recoveryAction: .retryTransfer)
            }
        }
        return PlaybackDisplayError(title: "Playback command failed", message: error.localizedDescription, recoveryAction: .retryTransfer)
    }

    private func fallbackNowPlaying() -> PlaybackNowPlaying {
        PlaybackNowPlaying(name: "Spotify playback", artists: [], albumArtURL: nil, durationMilliseconds: 0, positionMilliseconds: 0, uri: nil)
    }
}

final class WebPlaybackViewCommander: WebPlaybackCommanding {
    weak var webView: WKWebView?

    func loadHost() {
        webView?.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
    }

    @MainActor
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any] = [:]) async throws {
        guard let webView else { return }
        let script = try commandScript(command, payload: payload)
        _ = try await webView.evaluateJavaScript(script)
    }

    private func commandScript(_ command: PlaybackBridgeCommand, payload: [String: Any]) throws -> String {
        switch command {
        case .connect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.connect();"
        case .disconnect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.disconnect();"
        case .togglePlay:
            return "window.spotiglassPlayback && window.spotiglassPlayback.togglePlay();"
        case .pause:
            return "window.spotiglassPlayback && window.spotiglassPlayback.pause();"
        case .resume:
            return "window.spotiglassPlayback && window.spotiglassPlayback.resume();"
        case .seek:
            let milliseconds = payload["milliseconds"] as? Int ?? 0
            return "window.spotiglassPlayback && window.spotiglassPlayback.seek(\(milliseconds));"
        case .next:
            return "window.spotiglassPlayback && window.spotiglassPlayback.next();"
        case .previous:
            return "window.spotiglassPlayback && window.spotiglassPlayback.previous();"
        case .playURI:
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return "window.spotiglassPlayback && window.spotiglassPlayback.playURI(\(json).uri);"
        }
    }
}
