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
    static let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Spotiglass Playback Host</title>
      <script src="https://sdk.scdn.co/spotify-player.js"></script>
    </head>
    <body>
      <script>
        (() => {
          const swift = window.webkit.messageHandlers.spotiglassPlayback;
          let player = null;
          let deviceId = null;

          function post(name, payload = {}) {
            swift.postMessage({ name, payload });
          }

          async function requestToken(refresh = false) {
            return await window.webkit.messageHandlers.spotiglassToken.postMessage({ refresh });
          }

          window.onSpotifyWebPlaybackSDKReady = () => {
            player = new Spotify.Player({
              name: 'Spotiglass',
              getOAuthToken: async callback => {
                try {
                  const response = await requestToken(false);
                  callback(response.accessToken);
                } catch (error) {
                  post('authentication_error', { message: String(error && error.message ? error.message : error) });
                }
              },
              volume: 0.8
            });

            player.addListener('ready', ({ device_id }) => {
              deviceId = device_id;
              post('ready', { deviceID: device_id });
            });
            player.addListener('not_ready', ({ device_id }) => post('not_ready', { deviceID: device_id }));
            player.addListener('initialization_error', ({ message }) => post('initialization_error', { message }));
            player.addListener('authentication_error', ({ message }) => post('authentication_error', { message }));
            player.addListener('account_error', ({ message }) => post('account_error', { message }));
            player.addListener('playback_error', ({ message }) => post('playback_error', { message }));
            player.addListener('player_state_changed', state => post('state_changed', normalizeState(state)));
            post('log', { message: 'Spotify Web Playback SDK host initialized' });

            // Auto-connect once the SDK is ready: the Swift host calls
            // spotiglassPlayback.connect immediately after loading this page,
            // which can race with the SDK script finishing. Connecting here
            // guarantees the player joins the device list without the user
            // having to click Connect twice.
            player.connect().then(success => {
              if (!success) {
                post('initialization_error', { message: 'Spotify Web Playback SDK could not connect to Spotify.' });
              }
            }).catch(error => {
              post('initialization_error', { message: String(error && error.message ? error.message : error) });
            });
          };

          function mapNextTrack(t) {
            const albumName = t.album && t.album.name ? String(t.album.name) : null;
            return {
              name: t.name || '',
              artists: (t.artists || []).map(artist => artist.name).filter(Boolean),
              albumName: albumName && albumName.length ? albumName : null,
              albumArtURL: t.album && t.album.images && t.album.images[0] ? t.album.images[0].url : null,
              durationMilliseconds: Number(t.duration_ms || 0),
              positionMilliseconds: 0,
              uri: t.uri || null
            };
          }

          function normalizeState(state) {
            if (!state || !state.track_window) {
              return { track: null, paused: true, nextTracks: [] };
            }
            const nextTracks = (state.track_window.next_tracks || []).map(mapNextTrack);
            if (!state.track_window.current_track) {
              return { track: null, paused: Boolean(state.paused), nextTracks };
            }
            const track = state.track_window.current_track;
            const albumName = track.album && track.album.name ? String(track.album.name) : null;
            return {
              paused: Boolean(state.paused),
              nextTracks,
              track: {
                name: track.name || '',
                artists: (track.artists || []).map(artist => artist.name).filter(Boolean),
                albumName: albumName && albumName.length ? albumName : null,
                albumArtURL: track.album && track.album.images && track.album.images[0] ? track.album.images[0].url : null,
                durationMilliseconds: Number(state.duration || 0),
                positionMilliseconds: Number(state.position || 0),
                uri: track.uri || null
              }
            };
          }

          // Every Web Playback SDK transport call (togglePlay, pause, seek, …)
          // returns a Promise. WKWebView's evaluateJavaScript cannot serialize
          // a Promise back to Swift and surfaces it as "JavaScript execution
          // returned a result of an unsupported type". To keep the bridge
          // synchronous from Swift's perspective we resolve the promises here
          // and forward rejections through the existing playback_error channel.
          // Each bridge function explicitly returns undefined.
          function runPlayerCommand(name, action) {
            if (!player) return;
            try {
              const result = action();
              if (result && typeof result.then === 'function') {
                result.catch(error => {
                  const message = error && error.message ? error.message : String(error);
                  post('playback_error', { message: `Spotify ${name} failed: ${message}` });
                });
              }
            } catch (error) {
              const message = error && error.message ? error.message : String(error);
              post('playback_error', { message: `Spotify ${name} threw: ${message}` });
            }
          }

            window.spotiglassPlayback = {
            connect: () => {
              if (!player) return;
              player.connect().then(success => {
                if (!success) {
                  post('initialization_error', { message: 'Spotify Web Playback SDK could not connect to Spotify.' });
                }
              }).catch(error => {
                const message = error && error.message ? error.message : String(error);
                post('initialization_error', { message });
              });
            },
            disconnect: () => { if (player) player.disconnect(); },
            togglePlay: () => runPlayerCommand('togglePlay', () => player.togglePlay()),
            pause: () => runPlayerCommand('pause', () => player.pause()),
            resume: () => runPlayerCommand('resume', () => player.resume()),
            seek: milliseconds => runPlayerCommand('seek', () => player.seek(milliseconds)),
            next: () => runPlayerCommand('next', () => player.nextTrack()),
            previous: () => runPlayerCommand('previous', () => player.previousTrack()),
            setVolume: fraction => {
              if (!player) return;
              const v = Math.min(1, Math.max(0, Number(fraction)));
              runPlayerCommand('setVolume', () => player.setVolume(v));
            },
            playURI: uri => post('log', { message: `playURI requested for ${uri} on ${deviceId || 'no-device'}` })
          };
        })();
      </script>
    </body>
    </html>
    """
}

enum SpotifyPlaybackBridgeParser {
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
        return PlaybackNowPlaying(
            name: track["name"] as? String ?? "Unknown track",
            artists: track["artists"] as? [String] ?? [],
            albumName: albumName,
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
        guard message.name == "spotiglassToken" else {
            replyHandler(nil, "Unsupported token bridge message")
            return
        }
        let refresh = (message.body as? [String: Any])?["refresh"] as? Bool ?? false
        Task {
            do {
                replyHandler(try await tokenBridge.tokenResponse(refresh: refresh), nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "spotiglassPlayback" else { return }
        do {
            onEvent?(try SpotifyPlaybackBridgeParser.parse(message.body))
        } catch {
            onEvent?(.playbackError("Invalid playback bridge message: \(error.localizedDescription)"))
        }
    }
}
