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
        let script = try WebPlaybackCommandScriptBuilder.script(for: command, payload: payload)
        _ = try await webView.evaluateJavaScript(script)
    }
}
