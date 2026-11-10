import SwiftUI

@main
struct SpotiglassApp: App {
    private let sparkleUpdater = SparkleUpdaterController()
    /// Keeps the unit-test host in the background (#418); a normal launch is untouched.
    @NSApplicationDelegateAdaptor(SpotiglassApplicationDelegate.self) private var applicationDelegate
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
    /// The narrowest a window gets with the queue closed.
    static let windowMinWidth: CGFloat = 520
    /// The shortest a window gets.
    static let windowMinHeight: CGFloat = 360

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
        _pinnedStore = StateObject(wrappedValue: PinnedItemsStore(cache: pinningCache) { pinID in
            AppleMusicArtworkRegistry.shared.url(forItemKey: pinID, size: AppleMusicItemMapping.ArtworkSize.cover)
        })
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
        playbackHosts.followSpotifySession(authVM.$state)
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
                appleMusicSession: appleMusicSession,
                // Screenshot mode keeps them in memory: its captures go public, so they must
                // never show (or add to) the searches of whoever runs it.
                recentSearches: ScreenshotMode.isActive ? .inMemory() : .userDefaults(.standard)
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
                // With the queue open the window keeps room for the detail column and the
                // panel at their minimums, so the panel is never cut off at its edge (#413).
                .frame(
                    minWidth: isQueueVisible
                        ? max(Self.windowMinWidth, SpotiglassDesign.detailAndQueueMinWidth)
                        : Self.windowMinWidth,
                    minHeight: Self.windowMinHeight
                )
        }
        .windowResizability(.contentMinSize)
        // The unit-test host opens no main window (#418): tests that need a window make their own.
        .defaultLaunchBehavior(AppMetadata.isRunningUnitTests ? .suppressed : .automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: sparkleUpdater.updater)
                Button(SpotiglassL10n.string("app.menu.openPalette", locale: settingsStore.appLocale)) {
                    sceneRegistry.activeScene?.performMenuCommand(CommandPaletteCommandID.openPalette)
                }
                // The palette belongs to a main window: with none open it has nowhere to show (#439).
                .disabled(sceneRegistry.activeScene == nil)
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

        // One window, not a group: opening it again brings it forward (#439). It shows the
        // app-scoped players, so closing it never stops the music.
        Window(
            SpotiglassL10n.string("lyrics.popOut.windowTitle", locale: settingsStore.appLocale),
            id: LyricsPopOutWindow.sceneID
        ) {
            LyricsPopOutRoot(playbackHosts: playbackHosts, serviceStore: serviceStore, keymapStore: keymapStore)
                .environmentObject(settingsStore)
                .environment(\.locale, settingsStore.appLocale)
                .environment(\.spotiglassLocale, settingsStore.appLocale)
                .id(settingsStore.settings.appearance.language.rawValue)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(LyricsPopOutWindow.defaultSize)
        // Its size and place are remembered by the window itself; it opens when asked, never
        // by itself at launch.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

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
                appleMusicSession: appleMusicSession,
                updater: sparkleUpdater.updater
            )
            .environmentObject(authViewModel)
            .environment(\.locale, settingsStore.appLocale)
            .environment(\.spotiglassLocale, settingsStore.appLocale)
            .preferredColorScheme(preferredColorScheme)
        }
    }
}

/// App-level AppKit hooks that SwiftUI has no scene modifier for.
final class SpotiglassApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Under `make test` the app is only the XCTest host. Several test runs share the Mac with
    /// people using it, so the host must never come to the front or take keyboard focus (#418).
    /// Setting the policy before launch finishes is what stops the launch-time activation.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard AppMetadata.isRunningUnitTests else { return }
        NSApp.setActivationPolicy(.prohibited)
    }

    /// Clicking the Dock icon with no main window open brings one back. The pop-out lyrics window
    /// counts as a visible window, so with only it open the system would bring nothing back
    /// (#439): open a main window the way File › New Window does.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch Self.reopenAction(for: sender.windows) {
        case .system:
            return true
        case let .restore(window):
            window.deminiaturize(nil)
        case .newWindow:
            Self.performNewWindow(in: sender.mainMenu)
        }
        return false
    }

    enum ReopenAction: Equatable {
        /// A main window or Settings is open: the system handles the click as before.
        case system
        /// Only the pop-out is open and a main window waits in the Dock: it comes back.
        case restore(NSWindow)
        /// Only the pop-out is open: a new main window, like File › New Window.
        case newWindow
    }

    @MainActor
    static func reopenAction(for windows: [NSWindow]) -> ReopenAction {
        guard onlyThePopOutIsOpen(windows) else { return .system }
        if let minimized = minimizedMainWindow(windows) { return .restore(minimized) }
        return .newWindow
    }

    /// A main window minimised to the Dock, if there is one; never Settings or another window.
    @MainActor
    static func minimizedMainWindow(_ windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.isMiniaturized && SpotiglassMainWindows.contains($0) }
    }

    /// True when the pop-out is the only window that could be a main window: no main window and
    /// no Settings, just the pop-out (menus, tooltips and panels don't count).
    @MainActor
    static func onlyThePopOutIsOpen(_ windows: [NSWindow]) -> Bool {
        let visible = windows.filter { $0.isVisible && $0.canBecomeMain }
        return !visible.isEmpty && visible.allSatisfy { LyricsPopOutWindow.isPopOut($0) }
    }

    /// Runs File › New Window (⌘N), the item SwiftUI adds for the main windows.
    @MainActor
    @discardableResult
    static func performNewWindow(in mainMenu: NSMenu?) -> Bool {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "n", item.keyEquivalentModifierMask == [.command], item.isEnabled {
                    return (menu, index)
                }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        guard let mainMenu, let (menu, index) = find(in: mainMenu) else { return false }
        menu.performActionForItem(at: index)
        return true
    }
}
