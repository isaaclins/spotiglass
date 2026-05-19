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
            settingsStore: store
        )
        .environmentObject(auth)
        ViewTestHost.host(view)

        let inspected = try view.inspect()
        for title in ["Playback", "Appearance", "Account", "Keyboard"] {
            XCTAssertNoThrow(try inspected.find(text: title))
        }
    }

    func testPlaybackSettingsView() throws {
        let view = PlaybackSettingsView()
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Premium and Web Playback"))
    }
}
