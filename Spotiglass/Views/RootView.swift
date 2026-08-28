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
}

/// Tracks the current main-window scene for app-level menu commands. The menu
/// and both transient controllers use this same active-scene policy; the
/// registry never detaches an inactive scene while another scene is alive.
@MainActor
final class SpotiglassSceneRegistry: ObservableObject {
    @Published private(set) var activeScene: SpotiglassSceneHost? = nil

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
    }

    /// Removes a scene from the live registry. Only the current host is
    /// detached: an inactive scene may disappear without tearing down the
    /// controller that still belongs to another live scene.
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
    let activate: () -> Void

    func makeNSView(context: Context) -> SceneHostActivationProbeView {
        SceneHostActivationProbeView(activate: activate)
    }

    func updateNSView(_ nsView: SceneHostActivationProbeView, context: Context) {
        nsView.activate = activate
        nsView.observeWindowIfNeeded()
    }
}

private final class SceneHostActivationProbeView: NSView {
    var activate: () -> Void
    private weak var observedWindow: NSWindow?
    private var keyWindowObserver: NSObjectProtocol?

    init(activate: @escaping () -> Void) {
        self.activate = activate
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
            activate()
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.activate()
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
        keyWindowObserver = nil
        observedWindow = nil
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @StateObject private var sceneHost: SpotiglassSceneHost
    private let sceneRegistry: SpotiglassSceneRegistry?
    /// Passed straight through to the playback session so a hardware output
    /// selection can be re-routed through the EQ instead of bypassing it
    /// (#253). Nil in previews/tests, where no engine owns the system route.
    private let equalizerEngine: AudioEqualizerEngine?
    @Environment(\.openSettings) private var openSettingsAction

    private var commandPaletteManager: CommandPaletteManager {
        sceneHost.commandPaletteManager
    }

    private var lyricsOverlayController: LyricsOverlayController {
        sceneHost.lyricsOverlayController
    }

    /// Standalone host (previews and view tests): no registry, so this scene
    /// always considers itself current.
    init(commandPaletteManager: CommandPaletteManager, equalizerEngine: AudioEqualizerEngine? = nil) {
        _sceneHost = StateObject(wrappedValue: SpotiglassSceneHost(commandPaletteManager: commandPaletteManager))
        sceneRegistry = nil
        self.equalizerEngine = equalizerEngine
    }

    init(
        keymapStore: CommandPaletteKeymapStore,
        sceneRegistry: SpotiglassSceneRegistry,
        equalizerEngine: AudioEqualizerEngine? = nil
    ) {
        _sceneHost = StateObject(
            wrappedValue: SpotiglassSceneHost(
                commandPaletteManager: CommandPaletteManager(keymapStore: keymapStore)
            )
        )
        self.sceneRegistry = sceneRegistry
        self.equalizerEngine = equalizerEngine
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
        return {
            prepareForAuthLoss()
            Task { await authViewModel.signOut() }
        }
    }

    /// Callbacks this scene owns regardless of auth state. ``detach`` clears
    /// them, so every path that detaches has to be able to restore them.
    private func wireSceneCallbacks() {
        commandPaletteManager.signOut = signOutAction
        commandPaletteManager.openSettings = {
            openSettingsAction()
        }
    }

    private func resetTransientStateForAuthLoss() {
        authLossPreparationAction()
    }

    var body: some View {
        content
            .environmentObject(lyricsOverlayController)
            // The lyrics surface is a full-window modal. Hide the complete
            // browser tree here, rather than only replacing the detail column,
            // so the sidebar, queue and playback chrome leave the VoiceOver
            // tree while the overlay is visible.
            .accessibilityHidden(lyricsOverlayController.isPresented)
            .overlay {
                LyricsOverlayLayer(
                    lyricsOverlay: lyricsOverlayController,
                    keymapStore: commandPaletteManager.keymapStore
                )
            }
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
                .accessibilityHidden(lyricsOverlayController.isPresented)
            }
            .background {
                CommandPaletteEventMonitor(manager: commandPaletteManager)
                    .frame(width: 0, height: 0)
            }
            .background {
                if let sceneRegistry {
                    SceneHostActivationView {
                        sceneRegistry.activate(sceneHost)
                    }
                    .frame(width: 0, height: 0)
                }
            }
            .task {
                await viewModel.restoreSessionIfAvailable()
            }
            .onAppear {
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
                    // A previous sign-out cleared every closure on this scene's
                    // palette, and `onAppear` does not run again for a root that
                    // stayed mounted. Re-arm them before the browser returns.
                    wireSceneCallbacks()
                    commandPaletteManager.isSignedIn = true
                case .signedOut, .signingIn, .failed, .refreshing(.none):
                    resetTransientStateForAuthLoss()
                    commandPaletteManager.isSignedIn = false
                    pinnedStore.clearForSignOut()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .signedIn, .refreshing(.some):
            PlaylistBrowserView(
                viewModel: .live(tokenProvider: viewModel),
                playbackTokenProvider: viewModel,
                searchTokenProvider: viewModel,
                commandPaletteManager: commandPaletteManager,
                signOut: signOutAction,
                equalizerEngine: equalizerEngine
            )
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
                        onSignOut: authLossPreparationAction
                    )
                }
                .padding(SpotiglassDesign.spacingL)
            }
            .frame(maxWidth: 560)
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
                    .frame(maxWidth: 420)
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
                    .frame(maxWidth: 420)
            }
        case .signedIn, .refreshing:
            EmptyView()
        }
    }
}

/// Renders ``ImmersiveLyricsView`` above the whole window (not only the split-view detail column).
private struct LyricsOverlayLayer: View {
    @ObservedObject var lyricsOverlay: LyricsOverlayController
    let keymapStore: CommandPaletteKeymapStore
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore

    /// Avoid blocking the window when `isPresented` is true before browse VC has called `attach` (nil models).
    private var immersiveLyricsReady: Bool {
        lyricsOverlay.isPresented
            && lyricsOverlay.playbackViewModel != nil
            && lyricsOverlay.queueViewModel != nil
            && lyricsOverlay.lyricsModel != nil
            && lyricsOverlay.navigateToArtist != nil
            && lyricsOverlay.navigateToAlbum != nil
    }

    var body: some View {
        ZStack {
            if immersiveLyricsReady,
                let playback = lyricsOverlay.playbackViewModel,
                let queue = lyricsOverlay.queueViewModel,
                let lyrics = lyricsOverlay.lyricsModel,
                let navigateArtist = lyricsOverlay.navigateToArtist,
                let navigateAlbum = lyricsOverlay.navigateToAlbum
            {
                LyricsOverlayFocusContainer(
                    content: ImmersiveLyricsView(
                        playbackViewModel: playback,
                        queueViewModel: queue,
                        lyricsModel: lyrics,
                        navigateToArtist: navigateArtist,
                        navigateToAlbum: navigateAlbum,
                        onDismiss: { lyricsOverlay.dismiss() }
                    )
                    .environmentObject(settingsStore),
                    isActive: immersiveLyricsReady,
                    keymapStore: keymapStore
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(200)
            }
        }
        .animation(.easeOut(duration: 0.22), value: lyricsOverlay.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(immersiveLyricsReady)
    }
}

#Preview {
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotiglassRootPreview-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json", isDirectory: false)
    return RootView(commandPaletteManager: CommandPaletteManager())
        .environmentObject(SpotiglassSettingsStore(fileURL: settingsURL))
        .environmentObject(AuthViewModel.preview())
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
}
