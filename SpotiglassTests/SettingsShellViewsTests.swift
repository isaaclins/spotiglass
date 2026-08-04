import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class SettingsShellViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testSpotiglassSettingsViewTabs() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let manager = CommandPaletteManager()
        let auth = AuthViewModel(refreshTokenStore: MemoryOnlyRefreshTokenStore())
        let view = SpotiglassSettingsView(
            commandPaletteManager: manager,
            settingsStore: store,
            equalizerEngine: AudioEqualizerEngine()
        )
        .environmentObject(auth)
        ViewTestHost.host(view)
        for key in [
            "settings.section.playback",
            "settings.section.equalizer",
            "settings.section.appearance",
            "settings.section.account",
            "settings.section.keyboard"
        ] {
            ViewTestHost.assertFindLocalizedText(key, in: view)
        }
    }

    func testPlaybackSettingsView() throws {
        let view = PlaybackSettingsView()
        ViewTestHost.host(view)
        ViewTestHost.assertFindLocalizedText("settings.playback.premium.title", in: view)
    }

    func testSettingsPanesLeaveScrollingToTheShell() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let manager = CommandPaletteManager()

        let appearance = AppearanceSettingsView(settingsStore: store)
        ViewTestHost.host(appearance)
        XCTAssertThrowsError(try appearance.inspect().find(ViewType.ScrollView.self))

        let playback = PlaybackSettingsView()
        ViewTestHost.host(playback)
        XCTAssertThrowsError(try playback.inspect().find(ViewType.ScrollView.self))

        let keyboard = CommandPaletteSettingsView(
            keymapStore: manager.keymapStore,
            commandPaletteManager: manager,
            presentation: .settingsTabs
        )
        ViewTestHost.host(keyboard)
        XCTAssertThrowsError(try keyboard.inspect().find(ViewType.ScrollView.self))

        let standaloneKeyboard = CommandPaletteSettingsView(
            keymapStore: manager.keymapStore,
            commandPaletteManager: manager,
            presentation: .standalone
        )
        ViewTestHost.host(standaloneKeyboard)
        XCTAssertNoThrow(try standaloneKeyboard.inspect().find(ViewType.ScrollView.self))
    }
}
