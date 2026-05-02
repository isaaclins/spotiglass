import SwiftUI

@main
struct SpotiglassApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var settingsStore: SpotiglassSettingsStore
    @StateObject private var equalizerEngine = AudioEqualizerEngine()
    @StateObject private var commandPaletteManager: CommandPaletteManager

    init() {
        let store = SpotiglassSettingsStore()
        let keymapStore = CommandPaletteKeymapStore(settingsStore: store)
        _settingsStore = StateObject(wrappedValue: store)
        _commandPaletteManager = StateObject(wrappedValue: CommandPaletteManager(keymapStore: keymapStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView(commandPaletteManager: commandPaletteManager)
                .environmentObject(authViewModel)
                .frame(minWidth: 520, minHeight: 360)
                .onAppear {
                    syncEqualizer(to: settingsStore.settings.equalizer)
                }
                .onChange(of: settingsStore.settings.equalizer) { _, equalizer in
                    syncEqualizer(to: equalizer)
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
}
