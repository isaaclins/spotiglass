import SwiftUI

@main
struct SpotiglassApp: App {
    private let sparkleUpdater = SparkleUpdaterController()
    @StateObject private var authViewModel: AuthViewModel
    @StateObject private var settingsStore: SpotiglassSettingsStore
    @StateObject private var commandPaletteManager: CommandPaletteManager
    @StateObject private var pinnedStore: PinnedItemsStore
    @StateObject private var lyricsOverlayController = LyricsOverlayController()
    @StateObject private var equalizerEngine: AudioEqualizerEngine

    init() {
        SpotiglassLog.boot()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SpotiglassLog.info(.persistence, "Spotiglass launching (version=\(version) build=\(build))")
        let store = SpotiglassSettingsStore()
        let keymapStore = CommandPaletteKeymapStore(settingsStore: store)
        _settingsStore = StateObject(wrappedValue: store)
        _commandPaletteManager = StateObject(wrappedValue: CommandPaletteManager(keymapStore: keymapStore))
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
        _equalizerEngine = StateObject(wrappedValue: AudioEqualizerEngine())
        SpotiglassL10n.settingsStore = store
    }

    private var preferredColorScheme: ColorScheme? {
        settingsStore.settings.appearance.colorScheme.preferredColorScheme
    }

    var body: some Scene {
        WindowGroup {
            RootView(commandPaletteManager: commandPaletteManager)
                .environmentObject(authViewModel)
                .environmentObject(settingsStore)
                .environmentObject(pinnedStore)
                .environmentObject(lyricsOverlayController)
                .environment(\.locale, settingsStore.appLocale)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: sparkleUpdater.updater)
            }
            CommandMenu(SpotiglassL10n.string("app.menu.name")) {
                Button(SpotiglassL10n.string("app.menu.openPalette")) {
                    commandPaletteManager.execute(commandID: CommandPaletteCommandID.openPalette)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        Settings {
            SpotiglassSettingsView(
                commandPaletteManager: commandPaletteManager,
                settingsStore: settingsStore,
                equalizerEngine: equalizerEngine
            )
            .environmentObject(authViewModel)
            .environment(\.locale, settingsStore.appLocale)
            .preferredColorScheme(preferredColorScheme)
        }
    }
}
