import Foundation
import WebKit

@MainActor
protocol PlaybackAccessTokenProviding: AnyObject {
    func playbackAccessToken() async throws -> String
    func refreshedPlaybackAccessToken() async throws -> String
}

final class PlaybackTokenBridge {
    private let provider: PlaybackAccessTokenProviding

    init(provider: PlaybackAccessTokenProviding) {
        self.provider = provider
    }

    func tokenResponse(refresh: Bool) async throws -> [String: String] {
        let token = try await (refresh ? provider.refreshedPlaybackAccessToken() : provider.playbackAccessToken())
        return ["accessToken": token]
    }
}

enum SpotifyPlaybackHost {
    /// Mirrors the device name passed to `new Spotify.Player({ name: 'Spotiglass' })` in the bundled host page.
    /// Swift code matches against this when deciding whether an active Spotify Connect device
    /// is a stale prior session of this app rather than the user's other Connect target.
    static let deviceName = "Spotiglass"

    static var html: String {
        guard let url = Bundle.main.url(forResource: "SpotifyPlaybackHost", withExtension: "html"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            SpotiglassLog.error(SpotiglassLog.playback, "Missing bundled SpotifyPlaybackHost.html")
            return "<html><body></body></html>"
        }
        return text
    }
}

enum SpotifyPlaybackBridgeParser {
    /// Parses `spotify:album:{id}` from the Web Playback SDK bridge payload.
    static func spotifyAlbumID(fromAlbumURI uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:album:") else { return nil }
        let id = uri.dropFirst("spotify:album:".count)
        let trimmed = String(id).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(_ body: Any) throws -> PlaybackBridgeEvent {
        guard let dictionary = body as? [String: Any],
              let name = dictionary["name"] as? String else {
            throw PlaybackBridgeMessageError.invalidEnvelope
        }
        let payload = dictionary["payload"] as? [String: Any] ?? [:]

        switch name {
        case "ready":
            guard let deviceID = payload["deviceID"] as? String, !deviceID.isEmpty else {
                throw PlaybackBridgeMessageError.missingPayload("deviceID")
            }
            return .ready(deviceID: deviceID)
        case "not_ready":
            guard let deviceID = payload["deviceID"] as? String, !deviceID.isEmpty else {
                throw PlaybackBridgeMessageError.missingPayload("deviceID")
            }
            return .notReady(deviceID: deviceID)
        case "state_changed":
            let isPaused = payload["paused"] as? Bool ?? true
            return .stateChanged(
                parseNowPlaying(from: payload["track"]),
                isPaused: isPaused,
                nextTracks: parseNowPlayingArray(from: payload["nextTracks"])
            )
        case "player_command_finished":
            guard let command = payload["command"] as? String, !command.isEmpty else {
                throw PlaybackBridgeMessageError.missingPayload("command")
            }
            return .playerCommandFinished(command: command)
        case "initialization_error":
            return .initializationError(message(from: payload))
        case "authentication_error":
            return .authenticationError(message(from: payload))
        case "account_error":
            return .accountError(message(from: payload))
        case "playback_error":
            return .playbackError(message(from: payload))
        case "log":
            return .log(message(from: payload))
        default:
            throw PlaybackBridgeMessageError.unsupportedEvent(name)
        }
    }

    private static func parseNowPlaying(from value: Any?) -> PlaybackNowPlaying? {
        guard let track = value as? [String: Any] else {
            return nil
        }
        let rawAlbum = track["albumName"] as? String
        let albumName = rawAlbum.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let albumURI = track["albumURI"] as? String
        return PlaybackNowPlaying(
            name: track["name"] as? String ?? "Unknown track",
            artists: track["artists"] as? [String] ?? [],
            albumName: albumName,
            albumID: Self.spotifyAlbumID(fromAlbumURI: albumURI),
            albumArtURL: (track["albumArtURL"] as? String).flatMap(URL.init(string:)),
            durationMilliseconds: track["durationMilliseconds"] as? Int ?? 0,
            positionMilliseconds: track["positionMilliseconds"] as? Int ?? 0,
            uri: track["uri"] as? String
        )
    }

    private static func parseNowPlayingArray(from value: Any?) -> [PlaybackNowPlaying] {
        guard let tracks = value as? [[String: Any]] else {
            return []
        }
        return tracks.compactMap { parseNowPlaying(from: $0) }
    }

    private static func message(from payload: [String: Any]) -> String {
        payload["message"] as? String ?? "Spotify playback reported an error."
    }
}

/// WKScriptMessage routing for the hidden playback web view (pure branches are unit-tested).
enum SpotifyPlaybackWebViewCoordinatorDispatch {
    static let tokenHandlerName = "spotiglassToken"
    static let playbackHandlerName = "spotiglassPlayback"

    static func tokenReply(
        handlerName: String,
        body: Any,
        refresh: Bool,
        tokenBridge: PlaybackTokenBridge
    ) async -> (payload: [String: String]?, error: String?) {
        guard handlerName == tokenHandlerName else {
            return (nil, "Unsupported token bridge message")
        }
        do {
            return (try await tokenBridge.tokenResponse(refresh: refresh), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    static func playbackEvent(body: Any) -> PlaybackBridgeEvent {
        do {
            return try SpotifyPlaybackBridgeParser.parse(body)
        } catch {
            return .playbackError("Invalid playback bridge message: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class SpotifyPlaybackWebViewCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    let tokenBridge: PlaybackTokenBridge
    var onEvent: ((PlaybackBridgeEvent) -> Void)?

    init(tokenBridge: PlaybackTokenBridge) {
        self.tokenBridge = tokenBridge
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let refresh = (message.body as? [String: Any])?["refresh"] as? Bool ?? false
        Task {
            let result = await SpotifyPlaybackWebViewCoordinatorDispatch.tokenReply(
                handlerName: message.name,
                body: message.body,
                refresh: refresh,
                tokenBridge: tokenBridge
            )
            replyHandler(result.payload, result.error)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == SpotifyPlaybackWebViewCoordinatorDispatch.playbackHandlerName else { return }
        onEvent?(SpotifyPlaybackWebViewCoordinatorDispatch.playbackEvent(body: message.body))
    }
}
