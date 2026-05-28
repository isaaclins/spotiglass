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
}
