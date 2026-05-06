import SwiftUI
import WebKit

struct HiddenPlaybackWebView: NSViewRepresentable {
    let commander: WebPlaybackViewCommander
    let coordinator: SpotifyPlaybackWebViewCoordinator

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        // Outbound SDK events (ready, state_changed, errors) use the plain
        // message handler so they're routed to the no-reply method that
        // forwards to onEvent. Registering this channel with the reply-capable
        // API would route every event into the token handler, which only
        // accepts spotiglassToken messages and rejects the rest, leaving the
        // SDK's ready event invisible to Swift.
        userContentController.add(coordinator, name: "spotiglassPlayback")
        // The token channel needs a synchronous reply so the SDK's
        // getOAuthToken callback can await the access token from Swift.
        userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "spotiglassToken")
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        commander.attach(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        commander.attach(webView: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "spotiglassPlayback")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "spotiglassToken", contentWorld: .page)
    }
}
