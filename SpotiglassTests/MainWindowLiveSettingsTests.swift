import AppKit
import MusicKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// After a live language switch the sidebar slid up under the window's close, minimise and zoom
/// buttons (#557), as it once did after a live switch to light mode (#406). The main window's
/// content was keyed on the language, so a switch replaced the browser's split view and every
/// toolbar item with new ones. The window keeps its toolbar across that, and sometimes laid it
/// out as if the window had no sidebar: the title moved next to the window buttons, the bar's
/// buttons moved to the sidebar's edge, and the sidebar lost its top inset, until the next
/// rebuild. These tests host the main window's content with the modifiers the window scene uses
/// and switch the language and the colour scheme under it, as Settings does: the window must keep
/// the split view, the toolbar items and the sidebar's inset it had.
@MainActor
final class MainWindowLiveSettingsTests: XCTestCase {
    override func tearDown() {
        SpotiglassL10n.settingsStore = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testLiveLanguageAndAppearanceSwitchesKeepTheSidebarUnderTheToolbar() async throws {
        let settings = try ViewTestHost.makeSettingsStore()
        // The app looks most strings up through this store, the toolbar's labels included.
        SpotiglassL10n.settingsStore = settings
        try settings.mutate {
            $0.appearance.language = .english
            $0.appearance.colorScheme = .dark
        }
        let window = try await hostMainWindow(settings: settings)
        let before = try XCTUnwrap(TitleBarLayout(window), "the library's split view never appeared")
        XCTAssertGreaterThan(before.sidebarTopInset, 0, "the sidebar starts under the window buttons")

        let changes: [(String, (inout SpotiglassSettingsFile) -> Void)] = [
            ("German", { $0.appearance.language = .german }),
            ("light", { $0.appearance.colorScheme = .light }),
            ("Spanish", { $0.appearance.language = .spanish }),
            ("system", { $0.appearance.colorScheme = .system }),
            ("English", { $0.appearance.language = .english }),
            ("dark", { $0.appearance.colorScheme = .dark }),
        ]
        for (name, change) in changes {
            try settings.mutate(change)
            settle(window)

            let after = try XCTUnwrap(TitleBarLayout(window), "no split view after switching to \(name)")
            XCTAssertTrue(after.splitView === before.splitView, "switching to \(name) replaced the window's split view")
            for (index, item) in after.items.enumerated() where !before.items.contains(where: { $0 === item }) {
                XCTFail("switching to \(name) replaced toolbar item \(index) (\(item.itemIdentifier.rawValue), \(item.label))")
            }
            XCTAssertTrue(
                after.sidebarSeparator?.splitView === after.splitView,
                "after switching to \(name) the toolbar's sidebar divider doesn't follow the window's split view"
            )
            XCTAssertEqual(
                after.sidebarTopInset, before.sidebarTopInset, accuracy: 0.5,
                "after switching to \(name) the sidebar moved up under the window buttons"
            )
        }
    }

    /// The main window's content, set up as the window scene sets it up, with Apple Music's
    /// library on screen (it needs no sign-in and no network here).
    private func hostMainWindow(settings: SpotiglassSettingsStore) async throws -> NSWindow {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic], active: .appleMusic
        ))
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        )
        let session = AppleMusicSession(authorization: LiveSettingsMusicAuthorization())
        await session.refresh()
        let spotifyHost = SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
            accessToken: "test", refreshedAccessToken: "test-refresh"
        ))
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: spotifyHost),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(auth)
        .environmentObject(settings)
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        .environmentObject(spotifyHost)
        .spotiglassLiveSettings(settings)

        let controller = ViewTestHost.host(root, size: CGSize(width: 1100, height: 700), measuresLayout: true)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = try XCTUnwrap(controller.view.window)
        // The app's window draws its content under the title bar, which is where the sidebar's
        // top inset comes from.
        window.styleMask.insert([.fullSizeContentView, .resizable, .miniaturizable])
        window.setContentSize(CGSize(width: 1100, height: 700))
        let appeared = AppKitTestSupport.pumpRunLoop(until: { TitleBarLayout(window)?.sidebarSeparator != nil })
        XCTAssertTrue(appeared, "the library and its toolbar never appeared")
        settle(window)
        return window
    }

    /// Runs the main run loop until the window has taken the change, then one display cycle more.
    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

/// What the title bar is laid out around: the browser's split view, the toolbar's items, the
/// divider item that splits the toolbar at the sidebar's edge, and the sidebar's top inset.
@MainActor
private struct TitleBarLayout {
    let splitView: NSSplitView
    let items: [NSToolbarItem]
    let sidebarSeparator: NSTrackingSeparatorToolbarItem?
    let sidebarTopInset: CGFloat

    init?(_ window: NSWindow) {
        guard let content = window.contentView, let split = Self.splitView(in: content),
            let sidebar = split.arrangedSubviews.first
        else { return nil }
        splitView = split
        items = window.toolbar?.items ?? []
        sidebarSeparator = items.lazy.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first
        sidebarTopInset = sidebar.safeAreaInsets.top
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2 { return split }
        for subview in view.subviews {
            if let found = splitView(in: subview) { return found }
        }
        return nil
    }
}

private struct LiveSettingsMusicAuthorization: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status { .authorized }
    func requestAuthorization() async -> MusicAuthorization.Status { .authorized }
    func canPlayCatalogContent() async -> Bool? { false }
}
