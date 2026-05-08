import Foundation
import WebKit

protocol WebPlaybackCommanding {
    func loadHost()
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws
}

final class WebPlaybackViewCommander: WebPlaybackCommanding {
    private weak var webView: WKWebView?
    /// Set when ``loadHost()`` runs before the `WKWebView` has been installed by
    /// `HiddenPlaybackWebView.makeNSView` (a real race on window reopen). The
    /// load is replayed in ``attach(webView:)`` once the WebView is available so
    /// the SDK host page is guaranteed to load.
    private var hostLoadPending = false

    func attach(webView: WKWebView?) {
        self.webView = webView
        if hostLoadPending, let webView {
            hostLoadPending = false
            webView.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
        }
    }

    func loadHost() {
        guard let webView else {
            hostLoadPending = true
            return
        }
        webView.loadHTMLString(SpotifyPlaybackHost.html, baseURL: URL(string: "https://spotiglass.local"))
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
        case .setVolume:
            let raw = (payload["volume"] as? NSNumber)?.doubleValue
                ?? (payload["volume"] as? Double)
                ?? (payload["volume"] as? Int).map(Double.init)
                ?? 0.8
            let clamped = min(max(raw, 0), 1)
            let literal = String(format: "%.6f", clamped)
            return "window.spotiglassPlayback && window.spotiglassPlayback.setVolume(\(literal));"
        }
    }
}
