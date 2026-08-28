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

    /// A Form's trailing spacer is part of its scroll document, so it must be
    /// large enough to let a last-row control clear the window edge at maximum
    /// scroll. Keep this assertion on the SwiftUI layout model rather than on
    /// AppKit's realised view hierarchy: macOS 26's headless runner does not
    /// expose the private focus-ring views that macOS 27 creates (#331).
    func testEqualizerScrollContentProvidesTrailingClearance() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let view = EqualizerSettingsView(
            settingsStore: store,
            engine: AudioEqualizerEngine()
        )
        let form = try view.inspect().find(ViewType.Form.self)
        let footerSection = try form.section(4)
        let trailingSpacer = try footerSection.find(ViewType.Color.self)
        let trailingInset = try trailingSpacer.fixedHeight()

        // Model the worst case: the Reset to Flat row ends exactly at the pane's
        // 641-point viewport edge before the trailing inset is added. The Form
        // document must then grow by the inset, making that row clearable at its
        // maximum scroll position.
        let layout = SettingsPaneScrollLayout(
            viewportHeight: 748 - 52 - 55,
            lastControlBottom: 748 - 52 - 55,
            trailingInset: trailingInset
        )

        XCTAssertGreaterThanOrEqual(trailingInset, SpotiglassDesign.spacingL)
        XCTAssertGreaterThan(layout.documentHeight, layout.viewportHeight)
        XCTAssertGreaterThan(layout.bottomClearanceAtMaximumScroll, 0)
        XCTAssertGreaterThanOrEqual(
            layout.bottomClearanceAtMaximumScroll,
            SpotiglassDesign.spacingL
        )
    }

    private struct SettingsPaneScrollLayout {
        let viewportHeight: CGFloat
        let lastControlBottom: CGFloat
        let trailingInset: CGFloat

        var documentHeight: CGFloat {
            lastControlBottom + trailingInset
        }

        var maximumScrollOffset: CGFloat {
            max(0, documentHeight - viewportHeight)
        }

        var bottomClearanceAtMaximumScroll: CGFloat {
            maximumScrollOffset + viewportHeight - lastControlBottom
        }
    }
}
