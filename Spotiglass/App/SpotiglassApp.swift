import Combine
import SwiftUI

@main
struct SpotiglassApp: App {
    @StateObject private var authViewModel: AuthViewModel
    @StateObject private var settingsStore: SpotiglassSettingsStore
    @StateObject private var equalizerEngine = AudioEqualizerEngine()
    @StateObject private var commandPaletteManager: CommandPaletteManager
    @StateObject private var pinnedStore: PinnedItemsStore
    @StateObject private var lyricsOverlayController = LyricsOverlayController()
    @State private var equalizerPlaybackSurfaceRebuildWorkItem: DispatchWorkItem?

    init() {
        let store = SpotiglassSettingsStore()
        let keymapStore = CommandPaletteKeymapStore(settingsStore: store)
        _settingsStore = StateObject(wrappedValue: store)
        _commandPaletteManager = StateObject(wrappedValue: CommandPaletteManager(keymapStore: keymapStore))
        let pinningCache: PinnedItemsCache = (try? SpotifyLocalCache()) ?? InMemoryPinnedItemsCache()
        _pinnedStore = StateObject(wrappedValue: PinnedItemsStore(cache: pinningCache))
        let authVM: AuthViewModel
        if AppMetadata.isRunningUnitTests {
            authVM = AuthViewModel(refreshTokenStore: MemoryOnlyRefreshTokenStore())
        } else {
            authVM = AuthViewModel()
        }
        _authViewModel = StateObject(wrappedValue: authVM)
    }

    var body: some Scene {
        WindowGroup {
            RootView(commandPaletteManager: commandPaletteManager)
                .environmentObject(authViewModel)
                .environmentObject(pinnedStore)
                .environmentObject(lyricsOverlayController)
                .frame(minWidth: 520, minHeight: 360)
                .onAppear {
                    syncEqualizer(to: settingsStore.settings.equalizer)
                }
                .onChange(of: settingsStore.settings.equalizer) { _, equalizer in
                    syncEqualizer(to: equalizer)
                }
                .onReceive(NotificationCenter.default.publisher(for: .spotiglassPlaybackDeviceReady)) { _ in
                    rebuildEqualizerTapIfEnabled()
                }
                .onReceive(NotificationCenter.default.publisher(for: .spotiglassPlaybackSurfaceAppeared)) { _ in
                    equalizerPlaybackSurfaceRebuildWorkItem?.cancel()
                    let store = settingsStore
                    let engine = equalizerEngine
                    let item = DispatchWorkItem {
                        let eq = store.settings.equalizer
                        guard eq.enabled else { return }
                        engine.restart(with: eq)
                    }
                    equalizerPlaybackSurfaceRebuildWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Spotiglass") {
                Button("Open Command Palette") {
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
        }
    }

    /// Reconciles the audio engine's running state with the persisted equalizer
    /// preferences after launch and after every change to ``settingsStore.settings.equalizer``.
    private func syncEqualizer(to equalizer: EqualizerSettings) {
        equalizerEngine.apply(settings: equalizer)
        if equalizer.enabled, !equalizerEngine.isRunning {
            do {
                try equalizerEngine.start()
                equalizerEngine.apply(settings: equalizer)
            } catch {
                try? settingsStore.mutate { $0.equalizer.enabled = false }
            }
        } else if !equalizer.enabled, equalizerEngine.isRunning {
            equalizerEngine.stop()
        }
    }

    /// Rebuilds the Core Audio process tap when EQ is on (WebKit helper PIDs may have changed).
    private func rebuildEqualizerTapIfEnabled() {
        let eq = settingsStore.settings.equalizer
        guard eq.enabled else { return }
        equalizerEngine.restart(with: eq)
    }
}
