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

/// One player per service (#373), app-wide like the choice of service. Every window, the menu
/// bar and Settings use the player of the service on screen.
///
/// Apple Music's player is created the first time Apple Music is on screen: creating it reaches
/// MusicKit, which a Spotify-only setup, screenshot mode and the unit-test host never should.
///
/// What's playing keeps playing across a switch, until something starts in the other library:
/// starting music in one player pauses the other. One rule holds across both (#396): what you
/// hear is what the bar and Space control (``PlaybackSessionViewModel/audiblePlayer``), and
/// signing out of a service stops its player.
@MainActor
final class SpotiglassPlaybackHosts: ObservableObject {
    let spotify: SpotiglassPlaybackHost
    private let makeAppleMusic: () -> SpotiglassPlaybackHost
    private(set) var appleMusicIfCreated: SpotiglassPlaybackHost?
    /// Fires once Apple Music's player exists, for views that follow it without creating it (the
    /// pop-out lyrics window, #439). Sent on the next turn: the player is often made mid-render.
    let appleMusicCreated = PassthroughSubject<Void, Never>()
    private var addedServices: [MusicService]?
    /// The service whose music you heard last (#468): the last player to start or play. A pause
    /// keeps it, so the bar stays on the song you paused, whichever service is on screen.
    private let lastHeardService = CurrentValueSubject<MusicService?, Never>(nil)
    private var cancellables: Set<AnyCancellable> = []

    init(spotify: SpotiglassPlaybackHost, makeAppleMusic: @escaping () -> SpotiglassPlaybackHost) {
        self.spotify = spotify
        self.makeAppleMusic = makeAppleMusic
    }

    var appleMusic: SpotiglassPlaybackHost {
        if let appleMusicIfCreated { return appleMusicIfCreated }
        let created = makeAppleMusic()
        link(spotify.playbackViewModel, created.playbackViewModel)
        link(created.playbackViewModel, spotify.playbackViewModel)
        appleMusicIfCreated = created
        DispatchQueue.main.async { [weak self] in self?.appleMusicCreated.send() }
        return created
    }

    /// Each player starts new music only while its service is on screen, so nothing from one
    /// library ever reaches the other service's player.
    func gate(activeService: MusicService?) {
        spotify.playbackViewModel.refusesNewPlayback = activeService != .spotify
        appleMusicIfCreated?.playbackViewModel.refusesNewPlayback = activeService != .appleMusic
    }

    /// Follows the added services (``MusicServiceStore/services``) for the whole app, with or
    /// without a window open.
    func follow<Services: Publisher>(addedServices services: Services)
    where Services.Output == [MusicService], Services.Failure == Never {
        services
            .sink { [weak self] in self?.servicesChanged(to: $0) }
            .store(in: &cancellables)
    }

    /// Spotify's session ending (signing out, a lapsed session) stops Spotify's player, for the
    /// whole app: with every main window closed, the pop-out lyrics window keeps its page alive
    /// (#439), and nothing else would stop music the app no longer has a session for.
    func followSpotifySession<States: Publisher>(_ states: States)
    where States.Output == AppConnectionState, States.Failure == Never {
        states
            .map(\.hasSpotifySession)
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let player = self?.spotify.playbackViewModel else { return }
                Task { await player.disconnect() }
            }
            .store(in: &cancellables)
    }

    /// Signing out of Apple Music removes it, and its player stops with it (#396): nothing keeps
    /// playing that the window offers no way to control, and adding it again starts fresh.
    /// Spotify's player stops when its session ends (``followSpotifySession(_:)``), which every
    /// removal of Spotify goes through.
    func servicesChanged(to services: [MusicService]) {
        defer { addedServices = services }
        guard let previous = addedServices,
              previous.contains(.appleMusic), !services.contains(.appleMusic),
              let appleMusic = appleMusicIfCreated?.playbackViewModel
        else { return }
        Task { await appleMusic.disconnect() }
    }

    /// `starting` pauses `other` when it starts music, and knows whether `other`'s music is the
    /// one you hear.
    private func link(_ starting: PlaybackSessionViewModel, _ other: PlaybackSessionViewModel) {
        let startingService = starting.service
        let otherService = other.service
        starting.onWillStartPlayback = { [weak other, lastHeardService] in
            // Set before `other` pauses: its pause must not make it the one you hear.
            lastHeardService.send(startingService)
            other?.pauseForHandover()
        }
        starting.otherServicePlayer = other
        // Music that starts in `other` by any way (its bar, another device, the Music app) makes
        // it the one you heard last.
        other.connectionStatePublisher
            .filter { PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: $0) }
            .sink { [lastHeardService] _ in
                if lastHeardService.value != otherService { lastHeardService.send(otherService) }
            }
            .store(in: &cancellables)
        // A paused song counts while `other` played last: pausing it keeps the bar on it, and
        // Play resumes it (#468). Signing out or nothing loaded leaves no song to follow.
        Publishers.CombineLatest(other.connectionStatePublisher, lastHeardService)
            .map { state, lastHeard in
                switch state {
                case .playing: true
                case .paused: lastHeard == otherService
                default: false
                }
            }
            .removeDuplicates()
            .sink { [weak starting] in starting?.isOtherServiceHeard = $0 }
            .store(in: &cancellables)
        other.$repeatMode
            .sink { [weak starting] in starting?.otherServiceRepeatMode = $0 }
            .store(in: &cancellables)
        // From the published values, not `other.isTransportMutationReady`: a sink runs before
        // the property changes.
        Publishers.CombineLatest4(other.$isTransportStateKnown, other.connectionStatePublisher, other.$deviceID, other.$activePlaybackDeviceID)
            .map { known, state, deviceID, activeDeviceID in
                PlaybackSessionViewModel.isTransportMutationReady(
                    isTransportStateKnown: known,
                    connectionState: state,
                    commandDeviceID: activeDeviceID ?? deviceID
                )
            }
            .removeDuplicates()
            .sink { [weak starting] in starting?.isOtherServiceTransportMutationReady = $0 }
            .store(in: &cancellables)
    }
}

/// The one Web Playback SDK host for the application. Main-window scenes retain
/// only views of this object; they must never create another SDK player for the
/// same Spotify account.
@MainActor
final class SpotiglassPlaybackHost: ObservableObject {
    let playbackViewModel: PlaybackSessionViewModel
    let playbackProvider: any MusicPlaybackProvider
    let commander: WebPlaybackViewCommander

    /// The Web Playback SDK page. `nil` for a service whose player needs no web view.
    private let webView: AccessibilityHiddenPlaybackWebView?
    private weak var attachedContainer: SpotiglassPlaybackHostContainer?
    private var mountedContainers: [ObjectIdentifier: WeakContainer] = [:]

    init(
        tokenProvider: PlaybackAccessTokenProviding,
        equalizerEngine: AudioEqualizerEngine? = nil
    ) {
        let commander = WebPlaybackViewCommander()
        let playbackProvider = SpotifyPlaybackProvider(
            playbackAPI: SpotifyPlaybackAPI(tokenProvider: tokenProvider),
            webCommander: commander
        )
        let playbackViewModel = PlaybackSessionViewModel(
            provider: playbackProvider,
            equalizerEngine: equalizerEngine
        )
        let coordinator = SpotifyPlaybackWebViewCoordinator(
            tokenBridge: PlaybackTokenBridge(provider: tokenProvider)
        )
        coordinator.onEvent = { [weak playbackProvider] envelope in
            playbackProvider?.deliver(envelope)
        }

        let webView = HiddenPlaybackWebView.makeWebView(
            commander: commander,
            coordinator: coordinator
        )

        self.playbackViewModel = playbackViewModel
        self.playbackProvider = playbackProvider
        self.commander = commander
        self.webView = webView
    }

    /// A host for a service whose player runs without a web view (Apple Music's
    /// `ApplicationMusicPlayer`). Containers still mount, but there is nothing to attach.
    init(
        provider: any MusicPlaybackProvider,
        equalizerEngine: AudioEqualizerEngine? = nil
    ) {
        self.playbackProvider = provider
        self.playbackViewModel = PlaybackSessionViewModel(
            provider: provider,
            equalizerEngine: equalizerEngine
        )
        self.commander = WebPlaybackViewCommander()
        self.webView = nil
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
        webView?.removeFromSuperview()
        attachedContainer = nil
        removeDeadContainers()
        if let replacement = mountedContainers.values.compactMap(\.value).first {
            attachWebView(to: replacement)
        }
    }

    private func attachWebView(to container: SpotiglassPlaybackHostContainer) {
        guard let webView else { return }
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
