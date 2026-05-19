import SwiftUI
import WebKit

enum HiddenPlaybackWebViewConfiguration {
    static let playbackHandlerName = "spotiglassPlayback"
    static let tokenHandlerName = "spotiglassToken"

    static func make(coordinator: SpotifyPlaybackWebViewCoordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(coordinator, name: playbackHandlerName)
        userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: tokenHandlerName)
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }
}

struct HiddenPlaybackWebView: NSViewRepresentable {
    let commander: WebPlaybackViewCommander
    let coordinator: SpotifyPlaybackWebViewCoordinator

    func makeNSView(context: Context) -> WKWebView {
        let configuration = HiddenPlaybackWebViewConfiguration.make(coordinator: coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        commander.attach(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        commander.attach(webView: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: HiddenPlaybackWebViewConfiguration.playbackHandlerName
        )
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: HiddenPlaybackWebViewConfiguration.tokenHandlerName,
            contentWorld: .page
        )
    }
}
