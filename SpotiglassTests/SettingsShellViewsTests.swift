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
            "settings.section.playback",
            "settings.section.equalizer",
            "settings.section.appearance",
            "settings.section.account",
            "settings.section.keyboard"
        ] {
            ViewTestHost.assertFindLocalizedText(key, in: view)
        }
    }

    /// The Settings window must open with its navigation list on screen (#23
    /// regression): AppKit autosaves the split view's collapsed flag, so the
    /// shell has to drive column visibility itself instead of inheriting a
    /// remembered "Hide Sidebar" click.
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
        ViewTestHost.host(view.environmentObject(auth))

        let visibilities = Self.columnVisibilities(in: view.body)
        XCTAssertFalse(
            visibilities.isEmpty,
            "The settings shell must bind NavigationSplitView's column visibility"
        )
        for visibility in visibilities {
            XCTAssertEqual(visibility, .all, "The sidebar column must start visible")
        }
    }

    /// Collects every `NavigationSplitViewVisibility` the view tree binds, so
    /// the assertion above reads the value SwiftUI would apply on open.
    private static func columnVisibilities(in value: Any) -> [NavigationSplitViewVisibility] {
        var found: [NavigationSplitViewVisibility] = []
        var seen = 0
        func walk(_ node: Any) {
            seen += 1
            if seen > 4000 { return }
            if let binding = node as? Binding<NavigationSplitViewVisibility> {
                found.append(binding.wrappedValue)
                return
            }
            if let visibility = node as? NavigationSplitViewVisibility {
                found.append(visibility)
                return
            }
            for child in Mirror(reflecting: node).children { walk(child.value) }
        }
        walk(value)
        return found
    }

    func testPlaybackSettingsView() throws {
        let view = PlaybackSettingsView()
        ViewTestHost.host(view)
        ViewTestHost.assertFindLocalizedText("settings.playback.premium.title", in: view)
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

        let playback = PlaybackSettingsView()
        ViewTestHost.host(playback)
        XCTAssertThrowsError(try playback.inspect().find(ViewType.ScrollView.self))
        XCTAssertNoThrow(try playback.inspect().find(ViewType.Form.self))

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
