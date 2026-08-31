import Combine
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

/// Legacy one-view representable retained for callers that need an isolated
/// playback web view (for example, previews). Production uses
/// ``SpotiglassPlaybackHost`` below so only one such view is created per app.
struct HiddenPlaybackWebView: NSViewRepresentable {
    let commander: WebPlaybackViewCommander
    let coordinator: SpotifyPlaybackWebViewCoordinator

    func makeNSView(context: Context) -> AccessibilityHiddenPlaybackWebView {
        Self.makeWebView(commander: commander, coordinator: coordinator)
    }

    func updateNSView(_ nsView: AccessibilityHiddenPlaybackWebView, context: Context) {
        Self.hideFromAccessibility(nsView)
        commander.attach(webView: nsView)
    }

    static func makeWebView(
        commander: WebPlaybackViewCommander,
        coordinator: SpotifyPlaybackWebViewCoordinator
    ) -> AccessibilityHiddenPlaybackWebView {
        let configuration = HiddenPlaybackWebViewConfiguration.make(coordinator: coordinator)
        let webView = AccessibilityHiddenPlaybackWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        hideFromAccessibility(webView)
        commander.attach(webView: webView)
        return webView
    }

    private static func hideFromAccessibility(_ webView: AccessibilityHiddenPlaybackWebView) {
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

/// The one Web Playback SDK host for the application. Main-window scenes retain
/// only views of this object; they must never create another SDK player for the
/// same Spotify account.
@MainActor
final class SpotiglassPlaybackHost: ObservableObject {
    let playbackViewModel: PlaybackSessionViewModel
    let playbackAPI: SpotifyPlaybackControlling
    let commander: WebPlaybackViewCommander

    private let webView: AccessibilityHiddenPlaybackWebView
    private weak var attachedContainer: SpotiglassPlaybackHostContainer?
    private var mountedContainers: [ObjectIdentifier: WeakContainer] = [:]

    init(
        tokenProvider: PlaybackAccessTokenProviding,
        equalizerEngine: AudioEqualizerEngine? = nil
    ) {
        let commander = WebPlaybackViewCommander()
        let playbackAPI = SpotifyPlaybackAPI(tokenProvider: tokenProvider)
        let playbackViewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: commander,
            equalizerEngine: equalizerEngine
        )
        let coordinator = SpotifyPlaybackWebViewCoordinator(
            tokenBridge: PlaybackTokenBridge(provider: tokenProvider)
        )
        coordinator.onEvent = { [weak playbackViewModel] envelope in
            playbackViewModel?.handle(envelope)
        }

        let webView = HiddenPlaybackWebView.makeWebView(
            commander: commander,
            coordinator: coordinator
        )

        self.playbackViewModel = playbackViewModel
        self.playbackAPI = playbackAPI
        self.commander = commander
        self.webView = webView
    }

    /// Mounts the retained SDK web view into the first live scene container.
    /// Additional windows get an empty container and observe the same model.
    /// If the mounted scene closes, ``unmount(_:)`` moves this same web view to
    /// a surviving container instead of creating a second SDK player.
    func mount(_ container: SpotiglassPlaybackHostContainer) {
        let identifier = ObjectIdentifier(container)
        mountedContainers[identifier] = WeakContainer(container)
        removeDeadContainers()

        guard attachedContainer == nil else { return }
        attachWebView(to: container)
    }

    func unmount(_ container: SpotiglassPlaybackHostContainer) {
        mountedContainers.removeValue(forKey: ObjectIdentifier(container))
        container.playbackHost = nil

        guard attachedContainer === container else { return }
        webView.removeFromSuperview()
        attachedContainer = nil
        removeDeadContainers()
        if let replacement = mountedContainers.values.compactMap(\.value).first {
            attachWebView(to: replacement)
        }
    }

    private func attachWebView(to container: SpotiglassPlaybackHostContainer) {
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView.autoresizingMask = [.width, .height]
        commander.attach(webView: webView)
        attachedContainer = container
    }

    private func removeDeadContainers() {
        mountedContainers = mountedContainers.filter { $0.value.value != nil }
    }

    private final class WeakContainer {
        weak var value: SpotiglassPlaybackHostContainer?

        init(_ value: SpotiglassPlaybackHostContainer) {
            self.value = value
        }
    }
}

/// A scene-local placeholder that lets ``SpotiglassPlaybackHost`` keep its
/// single WebKit view attached to whichever main window is still alive.
@MainActor
final class SpotiglassPlaybackHostContainer: NSView {
    weak var playbackHost: SpotiglassPlaybackHost?

    override func removeFromSuperview() {
        playbackHost?.unmount(self)
        super.removeFromSuperview()
    }
}

/// Hosts the app-scoped playback web view without exposing it in the window's
/// accessibility tree. The representable itself is instantiated once per
/// scene, but the retained WKWebView is owned by ``SpotiglassPlaybackHost``.
struct SpotiglassPlaybackHostView: NSViewRepresentable {
    let host: SpotiglassPlaybackHost

    func makeNSView(context: Context) -> SpotiglassPlaybackHostContainer {
        let container = SpotiglassPlaybackHostContainer(frame: .zero)
        container.playbackHost = host
        host.mount(container)
        return container
    }

    func updateNSView(_ nsView: SpotiglassPlaybackHostContainer, context: Context) {
        nsView.playbackHost = host
        host.mount(nsView)
    }

    static func dismantleNSView(_ nsView: SpotiglassPlaybackHostContainer, coordinator: ()) {
        nsView.playbackHost?.unmount(nsView)
    }
}
