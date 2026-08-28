import Foundation
import WebKit

protocol WebPlaybackCommanding {
    func loadHost(generation: PlaybackHostGeneration)
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws
    func send(
        _ command: PlaybackBridgeCommand,
        payload: [String: Any],
        generation: PlaybackHostGeneration
    ) async throws
}

extension WebPlaybackCommanding {
    func send(
        _ command: PlaybackBridgeCommand,
        payload: [String: Any],
        generation: PlaybackHostGeneration
    ) async throws {
        try await send(command, payload: payload)
    }
}

final class WebPlaybackViewCommander: WebPlaybackCommanding {
    private weak var webView: WKWebView?
    private var loadedHostGeneration: PlaybackHostGeneration?
    /// Set when ``loadHost()`` runs before the app-scoped `WKWebView` has been
    /// installed by `SpotiglassPlaybackHostView.makeNSView` (a real race on
    /// window reopen). The
    /// load is replayed in ``attach(webView:)`` once the WebView is available so
    /// the SDK host page is guaranteed to load.
    private var hostLoadPendingGeneration: PlaybackHostGeneration?

    func attach(webView: WKWebView?) {
        self.webView = webView
        if let generation = hostLoadPendingGeneration, let webView {
            hostLoadPendingGeneration = nil
            webView.loadHTMLString(
                SpotifyPlaybackHost.html(forHostGeneration: generation),
                baseURL: URL(string: "https://spotiglass.local")
            )
        }
    }

    func loadHost(generation: PlaybackHostGeneration) {
        loadedHostGeneration = generation
        guard let webView else {
            hostLoadPendingGeneration = generation
            return
        }
        webView.loadHTMLString(
            SpotifyPlaybackHost.html(forHostGeneration: generation),
            baseURL: URL(string: "https://spotiglass.local")
        )
    }

    @MainActor
    func send(_ command: PlaybackBridgeCommand, payload: [String: Any] = [:]) async throws {
        guard let webView else { return }
        let script = try WebPlaybackCommandScriptBuilder.script(for: command, payload: payload)
        _ = try await webView.evaluateJavaScript(script)
    }

    @MainActor
    func send(
        _ command: PlaybackBridgeCommand,
        payload: [String: Any] = [:],
        generation: PlaybackHostGeneration
    ) async throws {
        guard !Task.isCancelled,
              loadedHostGeneration == nil || loadedHostGeneration == generation
        else { return }
        try await send(command, payload: payload)
    }
}
