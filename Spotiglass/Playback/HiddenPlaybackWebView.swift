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

final class AccessibilityHiddenPlaybackWebView: WKWebView {
    override func isAccessibilityElement() -> Bool {
        false
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityContents() -> [Any]? {
        []
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case .children, .contents:
            []
        default:
            super.accessibilityAttributeValue(attribute)
        }
    }
}

struct HiddenPlaybackWebView: NSViewRepresentable {
    let commander: WebPlaybackViewCommander
    let coordinator: SpotifyPlaybackWebViewCoordinator

    func makeNSView(context: Context) -> AccessibilityHiddenPlaybackWebView {
        let configuration = HiddenPlaybackWebViewConfiguration.make(coordinator: coordinator)
        let webView = AccessibilityHiddenPlaybackWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        hideFromAccessibility(webView)
        commander.attach(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: AccessibilityHiddenPlaybackWebView, context: Context) {
        hideFromAccessibility(nsView)
        commander.attach(webView: nsView)
    }

    private func hideFromAccessibility(_ webView: AccessibilityHiddenPlaybackWebView) {
        webView.setAccessibilityElement(false)
        webView.setAccessibilityHidden(true)
    }

    static func dismantleNSView(_ nsView: AccessibilityHiddenPlaybackWebView, coordinator: ()) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: HiddenPlaybackWebViewConfiguration.playbackHandlerName
        )
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: HiddenPlaybackWebViewConfiguration.tokenHandlerName,
            contentWorld: .page
        )
    }
}
