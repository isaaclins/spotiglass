import AppKit
import Combine
import SwiftUI

/// The transient controllers belong to one main-window scene together. Keeping
/// them in this scene host prevents one `WindowGroup` root from replacing or
/// tearing down another root's palette or lyrics state.
@MainActor
final class SpotiglassSceneHost: ObservableObject {
    let commandPaletteManager: CommandPaletteManager
    let lyricsOverlayController: LyricsOverlayController
    /// The main window this scene runs in, set when it becomes key. Show/Hide Sidebar
    /// compares it with the window in front (#436).
    weak var window: NSWindow?
    /// Each service's browser state, kept while another service is on screen, so switching back
    /// shows that library instantly at the place it was left (#373). Dropped when the service's
    /// session ends.
    private var browserViewModels: [MusicService: PlaylistBrowserViewModel] = [:]

    private var childCancellables: Set<AnyCancellable> = []

    init(commandPaletteManager: CommandPaletteManager) {
        self.commandPaletteManager = commandPaletteManager
        self.lyricsOverlayController = LyricsOverlayController()

        commandPaletteManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childCancellables)
        lyricsOverlayController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childCancellables)
    }

    /// Clears all scene-local presentation state and callbacks before the scene
    /// is replaced by signed-out content or is torn down.
    func resetTransientState() {
        commandPaletteManager.detach()
        lyricsOverlayController.detach()
    }

    /// Runs a menu command in this scene. Chosen while the pop-out lyrics window has focus, a
    /// command that changes this window brings it forward first, so nothing changes out of sight
    /// behind the pop-out (#439).
    func performMenuCommand(_ commandID: String, keyWindow: NSWindow? = NSApp.keyWindow) {
        if LyricsPopOutWindow.bringsMainWindowForward(for: commandID, keyWindow: keyWindow) {
            window?.makeKeyAndOrderFront(nil)
        }
        commandPaletteManager.execute(commandID: commandID)
    }

    func browserViewModel(
        for service: MusicService,
        make: () -> PlaylistBrowserViewModel
    ) -> PlaylistBrowserViewModel {
        if let existing = browserViewModels[service] {
            return existing
        }
        let created = make()
        browserViewModels[service] = created
        return created
    }

    func discardBrowserViewModel(for service: MusicService) {
        browserViewModels[service] = nil
    }
}

/// Tracks the current main-window scene for app-level menu commands. The menu
/// and both transient controllers use this same active-scene policy; the
/// registry never detaches an inactive scene while another scene is alive.
@MainActor
final class SpotiglassSceneRegistry: ObservableObject {
    @Published private(set) var activeScene: SpotiglassSceneHost? = nil
    /// False while another window (Settings) is key. The View menu's Show/Hide Sidebar then
    /// acts on that window, so it can't show the browser's sidebar state (#436).
    @Published private(set) var isMainWindowInFront = true

    private var scenes: [SpotiglassSceneHost] = []
    private var activeSceneCancellable: AnyCancellable?

    /// Registers a live scene without changing which scene owns app-level
    /// commands. The activation probe promotes a scene only when its window is
    /// actually key; the first registered scene is the fallback until then.
    func register(_ scene: SpotiglassSceneHost) {
        if !scenes.contains(where: { $0 === scene }) {
            scenes.append(scene)
        }
        if activeScene == nil {
            setActiveScene(scene)
        }
    }

    /// Marks a scene as the current command host. This is called by the key
    /// window probe and is also useful to callers that explicitly select a
    /// scene (including tests).
    func activate(_ scene: SpotiglassSceneHost) {
        register(scene)
        setActiveScene(scene)
        if !isMainWindowInFront { isMainWindowInFront = true }
    }

    /// A main window stopped being key. Another main window becoming key calls `activate`
    /// right after, so this stays false only while some other window is in front.
    func mainWindowResignedKey() {
        if isMainWindowInFront { isMainWindowInFront = false }
    }

    /// Removes a scene from the live registry. Only the current host is
    /// detached: an inactive scene may disappear without tearing down the
    /// controller that still belongs to another live scene. Playback is
    /// app-scoped and intentionally is not reset here; its single WebKit view
    /// migrates independently to any surviving scene.
    func deactivate(_ scene: SpotiglassSceneHost) {
        let wasCurrentHost = activeScene === scene
        scenes.removeAll { $0 === scene }
        guard wasCurrentHost else { return }
        scene.resetTransientState()
        setActiveScene(scenes.last)
    }

    /// Auth loss can be initiated from the Settings scene, so every live main
    /// window is reset before the shared auth state replaces its browser.
    func resetTransientState() {
        for scene in scenes {
            scene.resetTransientState()
        }
    }

    /// Hotkey recording belongs to the Settings scene, but every main-window
    /// event monitor must yield while it is active.
    func setHotkeyRecording(_ isRecording: Bool) {
        for scene in scenes {
            scene.commandPaletteManager.isRecordingHotkey = isRecording
        }
    }

    private func setActiveScene(_ scene: SpotiglassSceneHost?) {
        if activeScene == nil, scene == nil { return }
        if let activeScene, let scene, activeScene === scene { return }

        activeSceneCancellable?.cancel()
        activeScene = scene
        guard let scene else { return }
        activeSceneCancellable = scene.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

/// A zero-sized AppKit probe makes menu routing follow the key main window,
/// rather than only the last window that happened to appear.
private struct SceneHostActivationView: NSViewRepresentable {
    let activate: (NSWindow) -> Void
    let resignKey: () -> Void

    func makeNSView(context: Context) -> SceneHostActivationProbeView {
        SceneHostActivationProbeView(activate: activate, resignKey: resignKey)
    }

    func updateNSView(_ nsView: SceneHostActivationProbeView, context: Context) {
        nsView.activate = activate
        nsView.resignKey = resignKey
        nsView.observeWindowIfNeeded()
    }
}

private final class SceneHostActivationProbeView: NSView {
    var activate: (NSWindow) -> Void
    var resignKey: () -> Void
    private weak var observedWindow: NSWindow?
    private var keyWindowObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    init(activate: @escaping (NSWindow) -> Void, resignKey: @escaping () -> Void) {
        self.activate = activate
        self.resignKey = resignKey
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowIfNeeded()
    }

    func observeWindowIfNeeded() {
        guard window !== observedWindow else { return }
        stopObservingWindow()
        guard let window else { return }

        observedWindow = window
        if window.isKeyWindow {
            activate(window)
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            self?.activate(window)
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.resignKey()
        }
    }

    override func removeFromSuperview() {
        stopObservingWindow()
        super.removeFromSuperview()
    }

    deinit {
        stopObservingWindow()
    }

    private func stopObservingWindow() {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        keyWindowObserver = nil
        resignKeyObserver = nil
        observedWindow = nil
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @StateObject private var sceneHost: SpotiglassSceneHost
    private let sceneRegistry: SpotiglassSceneRegistry?
    /// The app-scoped players, one per service (#373); Spotify's owns the single Web Playback SDK host.
    private let playbackHosts: SpotiglassPlaybackHosts
    /// The added services and the one on screen, app-wide (#373).
    @ObservedObject private var serviceStore: MusicServiceStore
    /// Apple Music permission state, shared app-wide with the menu bar and Settings.
    @ObservedObject private var appleMusicSession: AppleMusicSession
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    private var commandPaletteManager: CommandPaletteManager {
        sceneHost.commandPaletteManager
    }

    private var lyricsOverlayController: LyricsOverlayController {
        sceneHost.lyricsOverlayController
    }

    /// Standalone host (previews and view tests): no registry, so this scene
    /// always considers itself current.
    init(
        commandPaletteManager: CommandPaletteManager,
        playbackHost: SpotiglassPlaybackHost
    ) {
        _sceneHost = StateObject(wrappedValue: SpotiglassSceneHost(commandPaletteManager: commandPaletteManager))
        sceneRegistry = nil
        playbackHosts = Self.hosts(spotify: playbackHost)
        _serviceStore = ObservedObject(wrappedValue: MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        ))
        _appleMusicSession = ObservedObject(wrappedValue: AppleMusicSession())
    }

    init(
        keymapStore: CommandPaletteKeymapStore,
        sceneRegistry: SpotiglassSceneRegistry,
        playbackHosts: SpotiglassPlaybackHosts,
        serviceStore: MusicServiceStore,
        appleMusicSession: AppleMusicSession
    ) {
        _sceneHost = StateObject(
            wrappedValue: SpotiglassSceneHost(
                commandPaletteManager: CommandPaletteManager(keymapStore: keymapStore)
            )
        )
        self.sceneRegistry = sceneRegistry
        self.playbackHosts = playbackHosts
        _serviceStore = ObservedObject(wrappedValue: serviceStore)
        _appleMusicSession = ObservedObject(wrappedValue: appleMusicSession)
    }

    private static func hosts(spotify: SpotiglassPlaybackHost) -> SpotiglassPlaybackHosts {
        SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider())
        }
    }

    /// Clears all scene-local state before the shared auth state can replace a
    /// browser. Settings and the welcome screen use this preparation callback
    /// before invoking `AuthViewModel.signOut()` themselves.
    private var authLossPreparationAction: () -> Void {
        let host = self.sceneHost
        let registry = self.sceneRegistry
        return { [weak registry, weak host] in
            if let registry {
                registry.resetTransientState()
            } else {
                host?.resetTransientState()
            }
        }
    }

    /// Shared by the palette and browser disconnect button. The auth view's
    /// disconnect button invokes ``authLossPreparationAction`` and performs
    /// its own sign-out, so it does not receive this callback (which would
    /// otherwise start the auth transition twice).
    private var signOutAction: () -> Void {
        let authViewModel = self.viewModel
        let prepareForAuthLoss = authLossPreparationAction
        let serviceStore = self.serviceStore
        // Under Apple Music the browser supplies its own disconnect; this fallback must never
        // sign the Spotify account out (and delete its Keychain item) behind the user's back.
        guard serviceStore.active == .spotify else { return prepareForAuthLoss }
        return {
            prepareForAuthLoss()
            serviceStore.signOutRemoving(.spotify)
            Task { await authViewModel.signOut() }
        }
    }

    /// Switches every window to another added service. Each window's palette and lyrics state is
    /// cleared first, so nothing from one library can act on the other; playback is app-scoped and
    /// keeps playing (#373).
    private var switchServiceAction: (MusicService) -> Void {
        let serviceStore = self.serviceStore
        let prepare = authLossPreparationAction
        return { service in
            guard serviceStore.isAdded(service),
                serviceStore.active != service || serviceStore.pendingAddition != nil
            else { return }
            prepare()
            serviceStore.activate(service)
        }
    }

    /// Opens the pop-out lyrics window, or brings the one that is open forward (#439). The lyrics
    /// move there: this window's lyrics view closes.
    private var popOutLyricsAction: () -> Void {
        let openWindow = openWindowAction
        let lyricsOverlay = lyricsOverlayController
        return {
            lyricsOverlay.dismiss()
            openWindow(id: LyricsPopOutWindow.sceneID)
        }
    }

    /// "Add a service…" and the welcome screen: show that service's sign-in.
    private var addServiceAction: (MusicService) -> Void {
        let serviceStore = self.serviceStore
        let prepare = authLossPreparationAction
        return { service in
            prepare()
            serviceStore.beginAddition(of: service)
        }
    }

    /// Callbacks this scene owns regardless of auth state. ``detach`` clears
    /// them, so every path that detaches has to be able to restore them.
    private func wireSceneCallbacks() {
        // Apple Music has no Disconnect: its access is a system permission.
        commandPaletteManager.signOut = serviceStore.active == .spotify ? signOutAction : nil
        commandPaletteManager.openSettings = {
            openSettingsAction()
        }
        commandPaletteManager.switchService = switchServiceAction
        commandPaletteManager.popOutLyrics = popOutLyricsAction
        commandPaletteManager.switchableServices = serviceStore.switchTargets
    }

    private var isSpotifySignedIn: Bool {
        spotifyState.hasSpotifySession
    }

    /// Spotify's state as the window shows it: a session that is being signed out already lost its
    /// saved sign-in, so it counts as signed out at once (no old browser, no adding Spotify with it).
    private var spotifyState: AppConnectionState {
        viewModel.isSigningOut ? .signedOut : viewModel.state
    }

    /// The sign-in a pins list belongs to is the account's, not the service's: Spotify pins are
    /// keyed by the Spotify user ID exactly as before, Apple Music's by its library ID. On a
    /// switch the list is cleared at once and, when the other space's ID is already known, bound
    /// to it straight away, so pins never show (or get added to) the wrong library.
    private func rebindPinsForActiveService() {
        pinnedStore.clearForSignOut()
        guard let active = serviceStore.active, serviceStore.pendingAddition == nil else { return }
        if let userID = serviceStore.lastPinnedUserID[active] {
            pinnedStore.bind(userID: userID)
        }
    }

    private func resetTransientStateForAuthLoss() {
        authLossPreparationAction()
    }

    var body: some View {
        content
            // The lyrics surface lives in the browser's main column (`PlaylistBrowserView`), so the
            // sidebar, the toolbar and the player bar stay usable while it is open (#438).
            .environmentObject(lyricsOverlayController)
            .overlay {
                ZStack {
                    if commandPaletteManager.viewModel.isPresented {
                        CommandPaletteView(viewModel: commandPaletteManager.viewModel)
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                                    removal: .scale(scale: 0.98).combined(with: .opacity)
                                )
                            )
                    }
                }
                .animation(
                    .spring(response: 0.32, dampingFraction: 0.86),
                    value: commandPaletteManager.viewModel.isPresented
                )
            }
            .background {
                CommandPaletteEventMonitor(manager: commandPaletteManager)
                    .frame(width: 0, height: 0)
            }
            .background {
                SpotiglassPlaybackHostView(host: playbackHosts.spotify)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .background {
                if let sceneRegistry {
                    SceneHostActivationView(
                        activate: { window in
                            sceneHost.window = window
                            sceneRegistry.activate(sceneHost)
                        },
                        resignKey: { sceneRegistry.mainWindowResignedKey() }
                    )
                    .frame(width: 0, height: 0)
                }
            }
            .task {
                // A Spotify session is only restored when Spotify is added: an Apple Music-only
                // setup never reads the Spotify Keychain item.
                guard serviceStore.isAdded(.spotify) else { return }
                await viewModel.restoreSessionIfAvailable()
            }
            .onAppear {
                commandPaletteManager.sceneWindow = { [weak sceneHost] in sceneHost?.window }
                commandPaletteManager.isCurrentScene = { [weak sceneHost, weak sceneRegistry] in
                    guard let sceneRegistry else { return true }
                    guard let sceneHost else { return false }
                    return sceneRegistry.activeScene === sceneHost
                }
                sceneRegistry?.register(sceneHost)
                wireSceneCallbacks()
            }
            .onDisappear {
                if let sceneRegistry {
                    sceneRegistry.deactivate(sceneHost)
                } else {
                    // Preview/test roots have no registry, so their host is the
                    // only possible current scene.
                    sceneHost.resetTransientState()
                }
            }
            .onChange(of: viewModel.state) { _, newState in
                switch newState {
                case .signedIn, .refreshing(.some):
                    // Signing in to Spotify (welcome screen, "Add a service…" or Settings) adds it.
                    serviceStore.completeAddition(of: .spotify)
                    guard serviceStore.active == .spotify else {
                        commandPaletteManager.switchableServices = serviceStore.switchTargets
                        return
                    }
                    // A previous sign-out cleared every closure on this scene's
                    // palette, and `onAppear` does not run again for a root that
                    // stayed mounted. Re-arm them before the browser returns.
                    wireSceneCallbacks()
                    commandPaletteManager.isSignedIn = true
                case .signedOut, .signingIn, .failed, .refreshing(.none):
                    sceneHost.discardBrowserViewModel(for: .spotify)
                    serviceStore.lastPinnedUserID[.spotify] = nil
                    // Another service on screen keeps its browser, palette and pins.
                    guard serviceStore.active == .spotify else { return }
                    resetTransientStateForAuthLoss()
                    commandPaletteManager.isSignedIn = false
                    pinnedStore.clearForSignOut()
                }
            }
            .onChange(of: serviceStore.active) { _, _ in
                rebindPinsForActiveService()
                wireSceneCallbacks()
                if serviceStore.active == .spotify {
                    commandPaletteManager.isSignedIn = isSpotifySignedIn
                }
            }
            .onChange(of: serviceStore.active, initial: true) { _, active in
                // The players are app-wide: each starts new music only while its service is on screen.
                playbackHosts.gate(activeService: active)
            }
            .onChange(of: serviceStore.services) { _, _ in
                commandPaletteManager.switchableServices = serviceStore.switchTargets
                // Signing out of Apple Music ends its space: adding it again starts fresh instead of
                // showing the library and place from before the sign-out.
                if !serviceStore.isAdded(.appleMusic), serviceStore.pendingAddition != .appleMusic {
                    sceneHost.discardBrowserViewModel(for: .appleMusic)
                }
            }
            .onChange(of: serviceStore.pendingAddition) { old, new in
                // Leaving an unfinished Spotify sign-in closes its browser round trip too.
                if old == .spotify, new == nil, !serviceStore.isAdded(.spotify) {
                    viewModel.cancelSignIn()
                }
                // Spotify was still signed in (Settings): nothing to sign in to.
                if new == .spotify, isSpotifySignedIn {
                    serviceStore.completeAddition(of: .spotify)
                    return
                }
                // An addition that finished on the space already on screen: that space's browser
                // is up and binds its own pins. Clearing them here would throw its lookup away and
                // leave the new library without pins, dropping every pin made until the next switch.
                if let old, new == nil, serviceStore.active == old, serviceStore.isAdded(old) {
                    return
                }
                rebindPinsForActiveService()
            }
            .onChange(of: pinnedStore.boundUserID) { _, userID in
                guard let userID, let active = serviceStore.active, serviceStore.pendingAddition == nil else { return }
                serviceStore.lastPinnedUserID[active] = userID
            }
    }

    @ViewBuilder
    private var content: some View {
        switch serviceStore.active {
        case nil:
            MusicServiceWelcomeView(
                services: serviceStore.availableServices,
                choose: addServiceAction
            )
        case .spotify:
            spotifyContent
        case .appleMusic:
            AppleMusicBrowserRoot(
                session: appleMusicSession,
                playbackHost: playbackHosts.appleMusic,
                commandPaletteManager: commandPaletteManager,
                viewModel: sceneHost.browserViewModel(for: .appleMusic) {
                    AppleMusicBrowserRoot.makeViewModel()
                },
                isAdding: serviceStore.pendingAddition == .appleMusic,
                prepareForReset: authLossPreparationAction,
                rewireScene: { wireSceneCallbacks() },
                onAuthorized: { serviceStore.completeAddition(of: .appleMusic) },
                sidebarHeader: AnyView(serviceSwitcher),
                signInFooter: AnyView(signInFooter)
            )
        }
    }

    /// The service Disconnect hands the window to: ``MusicServiceStore/remove(_:)`` shows the
    /// first other added service. `nil` while Spotify is the only one (its sign-in comes back).
    private var spotifyDisconnectSwitchesTo: MusicService? {
        serviceStore.orderedServices.first { $0 != .spotify }
    }

    private var serviceSwitcher: some View {
        MusicServiceSwitcher(
            store: serviceStore,
            keymapStore: commandPaletteManager.keymapStore,
            switchTo: switchServiceAction,
            add: addServiceAction
        )
    }

    private var signInFooter: some View {
        MusicServiceSignInFooter(
            store: serviceStore,
            switchTo: switchServiceAction,
            add: addServiceAction
        )
    }

    @ViewBuilder
    private var spotifyContent: some View {
        switch spotifyState {
        case .signedIn, .refreshing(.some):
            PlaylistBrowserView(
                viewModel: sceneHost.browserViewModel(for: .spotify) {
                    .live(tokenProvider: viewModel)
                },
                playbackHost: playbackHosts.spotify,
                catalogProvider: SpotifyAPIClient(tokenProvider: viewModel, getResponseCache: .shared),
                commandPaletteManager: commandPaletteManager,
                signOut: signOutAction,
                disconnectSwitchesTo: spotifyDisconnectSwitchesTo,
                sidebarHeader: AnyView(serviceSwitcher)
            )
            .id(MusicService.spotify)
        case .refreshing(.none):
            ZStack {
                ShellBackground()
                GlassPanel {
                    VStack(spacing: SpotiglassDesign.spacingM) {
                        ProgressView()
                            .controlSize(.large)
                        Text(viewModel.state.title)
                            .font(.title2.weight(.semibold))
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(SpotiglassDesign.spacingXL)
                }
                .padding(SpotiglassDesign.spacingL)
            }
        case .signedOut, .signingIn, .failed:
            authContent
        }
    }

    private var authContent: some View {
        ZStack {
            ShellBackground()

            GlassPanel {
                VStack(spacing: SpotiglassDesign.spacingM) {
                    Label {
                        Text(AppMetadata.displayName)
                    } icon: {
                        Image(systemName: "music.note")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(.title2.weight(.semibold))
                    .labelStyle(.titleAndIcon)

                    authStatusMessage

                    SpotifyClientIDAndActionsView(
                        viewModel: viewModel,
                        layout: .welcome,
                        onSignOut: {
                            authLossPreparationAction()
                            serviceStore.signOutRemoving(.spotify)
                        },
                        disconnectRemovesService: serviceStore.signOutRemovesFromMenu(.spotify)
                    )

                    signInFooter
                }
                .padding(SpotiglassDesign.spacingL)
            }
            .frame(maxWidth: SpotiglassDesign.Layout.panelMaxWidth)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    @ViewBuilder
    private var authStatusMessage: some View {
        switch viewModel.state {
        case .signedOut:
            EmptyView()
        case .signingIn:
            VStack(alignment: .center, spacing: SpotiglassDesign.spacingXS) {
                Label(viewModel.state.title, systemImage: "safari")
                    .font(.subheadline.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text(viewModel.state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: SpotiglassDesign.Layout.paragraphMaxWidth)
            }
        case .failed:
            VStack(alignment: .center, spacing: SpotiglassDesign.spacingXS) {
                Label(viewModel.state.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text(viewModel.state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: SpotiglassDesign.Layout.paragraphMaxWidth)
            }
        case .signedIn, .refreshing:
            EmptyView()
        }
    }
}

#Preview {
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotiglassRootPreview-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json", isDirectory: false)
    let auth = AuthViewModel.preview()
    return RootView(
        commandPaletteManager: CommandPaletteManager(),
        playbackHost: SpotiglassPlaybackHost(tokenProvider: auth)
    )
        .environmentObject(SpotiglassSettingsStore(fileURL: settingsURL))
        .environmentObject(auth)
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
}
