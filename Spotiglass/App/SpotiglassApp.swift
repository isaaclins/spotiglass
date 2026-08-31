import SwiftUI

@main
struct SpotiglassApp: App {
    private let sparkleUpdater = SparkleUpdaterController()
    @StateObject private var authViewModel: AuthViewModel
    @StateObject private var settingsStore: SpotiglassSettingsStore
    /// Main-window palette state lives in each ``SpotiglassSceneHost``; the
    /// keymap store is the shared persisted dependency.
    @StateObject private var keymapStore: CommandPaletteKeymapStore
    @StateObject private var sceneRegistry = SpotiglassSceneRegistry()
    @StateObject private var pinnedStore: PinnedItemsStore
    @StateObject private var equalizerEngine: AudioEqualizerEngine
    /// The Spotify Web Playback SDK is account-scoped, so its model, commander
    /// and hidden web view live for the lifetime of the app rather than a
    /// particular WindowGroup scene.
    @StateObject private var playbackHost: SpotiglassPlaybackHost
    /// Same storage key ``PlaylistBrowserView`` writes, read here so the View menu
    /// can say "Show Queue" or "Hide Queue" instead of a stateless "Toggle".
    @AppStorage("queue.panel.visible") private var isQueueVisible = false

    init() {
        SpotiglassLog.boot()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SpotiglassLog.info(.persistence, "Spotiglass launching (version=\(version) build=\(build))")
        // Under the unit-test host, point the store at a throwaway file so running
        // tests never read, write, or migrate the developer's real settings (#27).
        let store: SpotiglassSettingsStore
        if AppMetadata.isRunningUnitTests {
            store = SpotiglassSettingsStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpotiglassTestHost-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false)
            )
        } else {
            store = SpotiglassSettingsStore()
        }
        let keymapStore = CommandPaletteKeymapStore(settingsStore: store)
        _settingsStore = StateObject(wrappedValue: store)
        _keymapStore = StateObject(wrappedValue: keymapStore)
        let pinningCache: PinnedItemsCache
        if let diskCache = try? SpotifyLocalCache() {
            pinningCache = diskCache
        } else {
            SpotiglassLog.info(SpotiglassLog.persistence, "Using in-memory pinned-items cache")
            pinningCache = InMemoryPinnedItemsCache()
        }
        _pinnedStore = StateObject(wrappedValue: PinnedItemsStore(cache: pinningCache))
        let authVM: AuthViewModel
        if AppMetadata.isRunningUnitTests {
            authVM = AuthViewModel(refreshTokenStore: MemoryOnlyRefreshTokenStore())
        } else {
            authVM = AuthViewModel()
        }
        _authViewModel = StateObject(wrappedValue: authVM)

        let equalizer = AudioEqualizerEngine()
        Self.restoreEqualizerIfEnabled(settingsStore: store, engine: equalizer)
        equalizer.observe(settingsStore: store)
        _equalizerEngine = StateObject(wrappedValue: equalizer)
        _playbackHost = StateObject(
            wrappedValue: SpotiglassPlaybackHost(
                tokenProvider: authVM,
                equalizerEngine: equalizer
            )
        )
        SpotiglassL10n.settingsStore = store
    }

    /// Re-engage the EQ only when the persisted master switch was on. The
    /// settings toggle is the source of truth across launches: an off value
    /// leaves the engine stopped, while an unavailable driver makes the failed
    /// enable explicit and resets the persisted switch instead of claiming the
    /// EQ is active.
    private static func restoreEqualizerIfEnabled(
        settingsStore: SpotiglassSettingsStore,
        engine: AudioEqualizerEngine
    ) {
        let equalizerSettings = settingsStore.settings.equalizer
        guard equalizerSettings.enabled else { return }

        engine.apply(settings: equalizerSettings)
        do {
            try engine.start(forwardingTargetUID: equalizerSettings.forwardingTargetUID)
        } catch {
            do {
                try settingsStore.mutate { $0.equalizer.enabled = false }
            } catch {
                SpotiglassLog.error(
                    .settings,
                    "Could not persist the disabled EQ state after startup restore failed: \(error.localizedDescription)"
                )
            }
            SpotiglassLog.error(
                .settings,
                "Equalizer startup restore failed: \(error.localizedDescription)"
            )
        }
    }

    private var preferredColorScheme: ColorScheme? {
        settingsStore.settings.appearance.colorScheme.preferredColorScheme
    }

    /// Mirrors the sign-in mapping ``RootView`` uses to gate the palette, so menu
    /// items dim in step with the commands actually being wired up.
    private var isSignedIn: Bool {
        switch authViewModel.state {
        case .signedIn, .refreshing(.some):
            true
        case .signedOut, .signingIn, .failed, .refreshing(.none):
            false
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                keymapStore: keymapStore,
                sceneRegistry: sceneRegistry,
                playbackHost: playbackHost
            )
                .environmentObject(authViewModel)
                .environmentObject(settingsStore)
                .environmentObject(pinnedStore)
                .environment(\.locale, settingsStore.appLocale)
                .environmentObject(playbackHost)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: sparkleUpdater.updater)
                Button(SpotiglassL10n.string("app.menu.openPalette")) {
                    sceneRegistry.activeScene?.commandPaletteManager.execute(
                        commandID: CommandPaletteCommandID.openPalette
                    )
                }
                // Derived from the keymap like every other menu item, so a
                // rebind moves the chord instead of leaving Command-K alive as
                // a second, undisclosed trigger (#131).
                .keyboardShortcut(
                    keymapStore.menuShortcut(
                        for: CommandPaletteCommandID.openPalette
                    )
                )
            }

            SpotiglassMenuCommands(
                sceneRegistry: sceneRegistry,
                keymapStore: keymapStore,
                isSignedIn: isSignedIn,
                isQueueVisible: isQueueVisible
            )
        }

        Settings {
            SpotiglassSettingsView(
                keymapStore: keymapStore,
                settingsStore: settingsStore,
                equalizerEngine: equalizerEngine,
                onSignOut: {
                    // The account view starts AuthViewModel.signOut() after this
                    // synchronous preparation; RootView also clears account-bound
                    // stores when the auth state publishes its loss.
                    sceneRegistry.resetTransientState()
                },
                onHotkeyRecordingChange: { isRecording in
                    sceneRegistry.setHotkeyRecording(isRecording)
                }
            )
            .environmentObject(authViewModel)
            .environment(\.locale, settingsStore.appLocale)
            .preferredColorScheme(preferredColorScheme)
        }
    }
}
