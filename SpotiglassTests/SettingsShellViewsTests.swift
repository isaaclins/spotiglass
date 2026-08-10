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
            "settings.section.keyboard",
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
        let auth = AuthViewModel(refreshTokenStore: MemoryOnlyRefreshTokenStore())
        let view = SpotiglassSettingsView(
            commandPaletteManager: manager,
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
