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
    /// One player per service (#373); Apple Music's is created the first time it's on screen.
    @StateObject private var playbackHosts: SpotiglassPlaybackHosts
    /// Apple Music access is a system permission for the whole app, so one session serves every
    /// window, the menu bar and Settings.
    @StateObject private var appleMusicSession = AppleMusicSession()
    /// The added services and the one on screen (#373), shared by every window, the menu bar
    /// and Settings.
    @StateObject private var serviceStore: MusicServiceStore
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
        } else if ScreenshotMode.isActive {
            authVM = AuthViewModel(
                refreshTokenStore: MemoryOnlyRefreshTokenStore(refreshToken: ScreenshotMode.refreshToken)
            )
        } else {
            authVM = AuthViewModel()
        }
        _authViewModel = StateObject(wrappedValue: authVM)
        let services = MusicServiceStore.live()
        services.followSpotifySignIn(authVM.$state)
        _serviceStore = StateObject(wrappedValue: services)

        let equalizer = AudioEqualizerEngine()
        // Screenshot mode never touches the audio driver, so a seeded EQ stays editable on screen.
        if !ScreenshotMode.isActive {
            Self.restoreEqualizerIfEnabled(settingsStore: store, engine: equalizer)
            equalizer.observe(settingsStore: store)
        }
        _equalizerEngine = StateObject(wrappedValue: equalizer)
        // Built lazily (after NSApp exists). Apple Music plays through MusicKit's own player:
        // no Web Playback SDK page, created only once Apple Music is on screen.
        let playbackHosts = SpotiglassPlaybackHosts(
            spotify: SpotiglassPlaybackHost(tokenProvider: authVM, equalizerEngine: equalizer),
            makeAppleMusic: {
                SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(), equalizerEngine: equalizer)
            }
        )
        // Signing out of a service stops its player, even with no window open (#396).
        playbackHosts.follow(addedServices: services.$services)
        _playbackHosts = StateObject(wrappedValue: playbackHosts)
        SpotiglassL10n.settingsStore = store
    }

    /// Re-engage the EQ only when the persisted master switch was on. The
    /// settings toggle is the source of truth across launches: an off value
    /// leaves the engine stopped, while an unavailable driver is logged and the
    /// persisted switch is reset instead of claiming the EQ is active.
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
        Self.menuIsSignedIn(
            service: serviceStore.active,
            spotifyState: authViewModel.state,
            appleMusicState: appleMusicSession.state
        )
    }

    /// Apple Music can play once the account has a subscription; Spotify always has its player.
    private var hasPlayback: Bool {
        switch serviceStore.active {
        case .spotify: true
        // Apple Music without a subscription can browse but not play.
        case .appleMusic: appleMusicSession.canPlayCatalogContent != false
        case nil: false
        }
    }

    /// Apple Music never signs in to Spotify: its permission is what wires the browser up, so
    /// under Apple Music the menu follows that permission instead of the Spotify session.
    static func menuIsSignedIn(
        service: MusicService?,
        spotifyState: AppConnectionState,
        appleMusicState: AppleMusicSession.State
    ) -> Bool {
        switch service {
        case nil:
            return false
        case .appleMusic:
            return appleMusicState == .authorized
        case .spotify:
            break
        }
        switch spotifyState {
        case .signedIn, .refreshing(.some):
            return true
        case .signedOut, .signingIn, .failed, .refreshing(.none):
            return false
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                keymapStore: keymapStore,
                sceneRegistry: sceneRegistry,
                playbackHosts: playbackHosts,
                serviceStore: serviceStore,
                appleMusicSession: appleMusicSession
            )
                .environmentObject(authViewModel)
                .environmentObject(settingsStore)
                .environmentObject(pinnedStore)
                .environment(\.locale, settingsStore.appLocale)
                .environment(\.spotiglassLocale, settingsStore.appLocale)
                .environmentObject(playbackHosts.spotify)
                .preferredColorScheme(preferredColorScheme)
                // List rows and other cached scene content can otherwise keep
                // the old localized strings. The host itself is app-scoped and
                // remains the same object across this scene replacement.
                .id(settingsStore.settings.appearance.language.rawValue)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: sparkleUpdater.updater)
                Button(SpotiglassL10n.string("app.menu.openPalette", locale: settingsStore.appLocale)) {
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

            // CommandMenu captures its title when the commands tree is
            // resolved. Keep the language in the tree identity so the menu bar
            // is rebuilt for every supported locale, not just its child labels.
            if settingsStore.settings.appearance.language == .english {
                SpotiglassMenuCommands(
                    sceneRegistry: sceneRegistry,
                    keymapStore: keymapStore,
                    settingsStore: settingsStore,
                    serviceStore: serviceStore,
                    isSignedIn: isSignedIn,
                    isQueueVisible: isQueueVisible,
                    hasPlayback: hasPlayback
                )
            } else if settingsStore.settings.appearance.language == .spanish {
                SpotiglassMenuCommands(
                    sceneRegistry: sceneRegistry,
                    keymapStore: keymapStore,
                    settingsStore: settingsStore,
                    serviceStore: serviceStore,
                    isSignedIn: isSignedIn,
                    isQueueVisible: isQueueVisible,
                    hasPlayback: hasPlayback
                )
            } else {
                SpotiglassMenuCommands(
                    sceneRegistry: sceneRegistry,
                    keymapStore: keymapStore,
                    settingsStore: settingsStore,
                    serviceStore: serviceStore,
                    isSignedIn: isSignedIn,
                    isQueueVisible: isQueueVisible,
                    hasPlayback: hasPlayback
                )
            }
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
                },
                serviceStore: serviceStore,
                appleMusicSession: appleMusicSession
            )
            .environmentObject(authViewModel)
            .environment(\.locale, settingsStore.appLocale)
            .environment(\.spotiglassLocale, settingsStore.appLocale)
            .preferredColorScheme(preferredColorScheme)
        }
    }
}
