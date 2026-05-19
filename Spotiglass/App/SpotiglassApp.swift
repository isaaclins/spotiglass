import SwiftUI

@main
struct SpotiglassApp: App {
    @StateObject private var authViewModel: AuthViewModel
    @StateObject private var settingsStore: SpotiglassSettingsStore
    @StateObject private var commandPaletteManager: CommandPaletteManager
    @StateObject private var pinnedStore: PinnedItemsStore
    @StateObject private var lyricsOverlayController = LyricsOverlayController()

    init() {
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
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Spotiglass") {
                Button(String(localized: "app.menu.openPalette")) {
                    commandPaletteManager.execute(commandID: CommandPaletteCommandID.openPalette)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        Settings {
            SpotiglassSettingsView(
                commandPaletteManager: commandPaletteManager,
                settingsStore: settingsStore
            )
            .environmentObject(authViewModel)
            .preferredColorScheme(preferredColorScheme)
        }
    }
}
