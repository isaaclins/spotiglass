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
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore()
        )
        let view = SpotiglassSettingsView(
            keymapStore: manager.keymapStore,
            settingsStore: store,
            equalizerEngine: AudioEqualizerEngine()
        )
        .environmentObject(auth)
        ViewTestHost.host(view)
        for key in [
            "settings.section.equalizer",
            "settings.section.appearance",
            "settings.section.account",
            "settings.section.keyboard"
        ] {
            ViewTestHost.assertFindLocalizedText(key, in: view)
        }
    }

    /// The Settings window must expose its native navigation shell (#23
    /// regression): AppKit autosaves the split view's collapsed flag, so the
    /// production shell binds column visibility explicitly instead of inheriting
    /// a remembered "Hide Sidebar" click. ViewInspector can verify the native
    /// sidebar/detail structure, but not SwiftUI's private binding storage.
    func testSettingsShellOpensWithTheSidebarVisible() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let manager = CommandPaletteManager()
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore()
        )
        let view = SpotiglassSettingsView(
            keymapStore: manager.keymapStore,
            settingsStore: store,
            equalizerEngine: AudioEqualizerEngine()
        )
        .environmentObject(auth)
        ViewTestHost.host(view)

        let splitView = try view.inspect().find(ViewType.NavigationSplitView.self)
        XCTAssertNoThrow(try splitView.sidebarView())
    }

    func testInformationalPlaybackPaneIsNotAdvertised() {
        XCTAssertEqual(
            SpotiglassSettingsSection.allCases,
            [.equalizer, .appearance, .account, .keyboard]
        )
    }

    /// Settings panes must never contain a bare `ScrollView`.
    ///
    /// Originally this held because the shell owned the only scroll container.
    /// The shell no longer scrolls: each pane is a grouped `Form`, which supplies
    /// its own scrolling and group insets, matching System Settings. The
    /// invariant that matters is unchanged and is what #21 and #22 actually
    /// regressed on: exactly one scrollable container per pane, never a
    /// hand-rolled `ScrollView` nested inside another one.
    ///
    /// The standalone Keyboard window is the deliberate exception. It is not
    /// hosted in the settings shell and is not a Form, so it brings its own.
    func testSettingsPanesLeaveScrollingToTheirFormContainer() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let manager = CommandPaletteManager()

        let appearance = AppearanceSettingsView(settingsStore: store)
        ViewTestHost.host(appearance)
        XCTAssertThrowsError(try appearance.inspect().find(ViewType.ScrollView.self))
        XCTAssertNoThrow(try appearance.inspect().find(ViewType.Form.self))

        let keyboard = CommandPaletteSettingsView(
            keymapStore: manager.keymapStore,
            presentation: .settingsTabs
        )
        ViewTestHost.host(keyboard)
        XCTAssertThrowsError(try keyboard.inspect().find(ViewType.ScrollView.self))

        let standaloneKeyboard = CommandPaletteSettingsView(
            keymapStore: manager.keymapStore,
            presentation: .standalone
        )
        ViewTestHost.host(standaloneKeyboard)
        XCTAssertNoThrow(try standaloneKeyboard.inspect().find(ViewType.ScrollView.self))
    }
}
