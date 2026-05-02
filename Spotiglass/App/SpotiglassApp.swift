import SwiftUI

@main
struct SpotiglassApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var commandPaletteManager = CommandPaletteManager()

    var body: some Scene {
        WindowGroup {
            RootView(commandPaletteManager: commandPaletteManager)
                .environmentObject(authViewModel)
                .frame(minWidth: 520, minHeight: 360)
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
            SpotiglassSettingsView(commandPaletteManager: commandPaletteManager)
                .environmentObject(authViewModel)
        }
    }
}
