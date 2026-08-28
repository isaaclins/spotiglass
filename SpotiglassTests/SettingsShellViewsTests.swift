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

    /// The production Settings window is 980×748 including its 52-point titlebar.
    /// Its 55-point detail header leaves this 641-point pane viewport. Host each
    /// real pane at that same viewport and move its native Form scroll view to
    /// the maximum offset, then assert its last focusable control is wholly
    /// inside the visible content rect. This covers the EQ footer as well as the
    /// Account, Appearance, and Keyboard panes at the realised window size (#331).
    func testSettingsPanesKeepTheirLastControlVisibleAtMaximumScroll() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let manager = CommandPaletteManager()
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore()
        )
        let realisedWindowSize = CGSize(
            width: SpotiglassDesign.settingsWindowWidth,
            height: 748
        )
        let paneSize = CGSize(
            width: realisedWindowSize.width,
            height: realisedWindowSize.height - 52 - 55
        )
        let panes: [(String, AnyView)] = [
            ("Equalizer", AnyView(EqualizerSettingsView(settingsStore: store, engine: AudioEqualizerEngine()))),
            ("Appearance", AnyView(AppearanceSettingsView(settingsStore: store))),
            ("Account", AnyView(AccountSettingsView(viewModel: auth))),
            (
                "Keyboard",
                AnyView(
                    CommandPaletteSettingsView(
                        keymapStore: manager.keymapStore,
                        presentation: .settingsTabs
                    )
                )
            ),
        ]

        for (name, pane) in panes {
            let controller = ViewTestHost.host(pane, size: paneSize)
            controller.view.frame = NSRect(origin: .zero, size: paneSize)
            controller.view.layoutSubtreeIfNeeded()

            let scrollView = try XCTUnwrap(
                allSubviews(of: controller.view)
                    .compactMap { $0 as? NSScrollView }
                    .first(where: { $0.documentView != nil })
            )
            let document = try XCTUnwrap(scrollView.documentView)
            let maximumOffset = max(0, document.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let lastControlFrame = try XCTUnwrap(
                lastFocusableControlFrame(in: document),
                "\(name) has no focusable control"
            )
            let visibleRect = scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: document
            )

            XCTAssertTrue(
                visibleRect.contains(lastControlFrame),
                "\(name)'s last control \(lastControlFrame) is outside the visible rect \(visibleRect) at offset \(maximumOffset)"
            )
            XCTAssertGreaterThanOrEqual(
                document.frame.maxY - lastControlFrame.maxY,
                32,
                "\(name)'s last control needs a bottom safety margin in the scroll document"
            )
        }
    }

    private func lastFocusableControlFrame(in document: NSView) -> NSRect? {
        allSubviews(of: document)
            .filter {
                String(describing: type(of: $0)).contains("FocusRingView")
                    && $0.frame.width < document.frame.width * 0.5
                    && $0.frame.height < 60
            }
            .compactMap { $0.superview?.convert($0.frame, to: document) }
            .max { $0.maxY < $1.maxY }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
