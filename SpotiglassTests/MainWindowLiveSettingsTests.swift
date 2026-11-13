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
        NSApp.appearance = nil
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
        let rendered = RenderedSettings()
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic, .spotify], active: .appleMusic
        ))
        let window = try await hostMainWindow(settings: settings, services: services, rendered: rendered)
        let before = try assertLiveSwitchesKeepTheTitleBar(of: window, settings: settings, rendered: rendered)

        // A service switch still builds a new browser, so it gets a new split view and new toolbar
        // items by design. The toolbar has to take them up: its divider follows the new split
        // view and the sidebar keeps its inset.
        let appleMusicLayout = try XCTUnwrap(TitleBarLayout(window))
        XCTAssertTrue(services.activate(.spotify), "couldn't switch to Spotify")
        // Spotify isn't signed in here, so its sign-in replaces the library.
        let leftAppleMusic = AppKitTestSupport.pumpRunLoop(until: {
            TitleBarLayout(window).map { $0.splitView !== appleMusicLayout.splitView } ?? true
        })
        XCTAssertTrue(leftAppleMusic, "switching to Spotify kept Apple Music's library on screen")
        XCTAssertTrue(services.activate(.appleMusic), "couldn't switch back to Apple Music")
        let back = AppKitTestSupport.pumpRunLoop(until: {
            guard let layout = TitleBarLayout(window) else { return false }
            return layout.splitView !== appleMusicLayout.splitView && layout.sidebarSeparator?.splitView === layout.splitView
        })
        window.contentView?.layoutSubtreeIfNeeded()
        let afterSwitch = try XCTUnwrap(TitleBarLayout(window), "no split view after switching back to Apple Music")
        XCTAssertTrue(back, "after switching services the toolbar's sidebar divider doesn't follow the new split view")
        XCTAssertEqual(
            afterSwitch.sidebarTopInset, before.sidebarTopInset, accuracy: 0.5,
            "after switching services the sidebar moved up under the window buttons"
        )
    }

    /// The same live switches over Spotify's library, as the main window shows it to a signed-in
    /// Spotify account: its own toolbar items (Disconnect among them) and live playback. Then
    /// straight from that library to Apple Music's and back, each a new split view and new toolbar
    /// items: the toolbar has to take each one up.
    func testLiveSwitchesKeepSpotifysSidebarUnderTheToolbar() async throws {
        let settings = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = settings
        try settings.mutate {
            $0.appearance.language = .english
            $0.appearance.colorScheme = .dark
        }
        let rendered = RenderedSettings()
        let (window, services) = try await hostSignedInLibraries(settings: settings, rendered: rendered)
        let start = try assertLiveSwitchesKeepTheTitleBar(of: window, settings: settings, rendered: rendered)

        for service in [MusicService.appleMusic, .spotify] {
            let shown = try XCTUnwrap(TitleBarLayout(window), "no library on screen before switching to \(service)")
            XCTAssertTrue(services.activate(service), "couldn't switch to \(service)")
            let switched = AppKitTestSupport.pumpRunLoop(until: {
                guard let layout = TitleBarLayout(window) else { return false }
                return layout.splitView !== shown.splitView && layout.sidebarSeparator?.splitView === layout.splitView
            })
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(switched, "after switching to \(service) the toolbar's sidebar divider doesn't follow its library")
            let after = try XCTUnwrap(TitleBarLayout(window), "no library after switching to \(service)")
            XCTAssertEqual(
                after.sidebarTopInset, start.sidebarTopInset, accuracy: 0.5,
                "after switching to \(service) the sidebar moved up under the window buttons"
            )
        }
    }

    /// System hands the content macOS's scheme itself, so it has to follow macOS turning dark or
    /// light while the app runs. The app's own appearance stands in for macOS's here.
    func testSystemFollowsMacOSTurningDarkOrLightLive() async throws {
        let settings = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = settings
        try settings.mutate {
            $0.appearance.language = .english
            $0.appearance.colorScheme = .system
        }
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic], active: .appleMusic
        ))
        let rendered = RenderedSettings()
        let window = try await hostMainWindow(settings: settings, services: services, rendered: rendered)
        let started = try XCTUnwrap(rendered.colorScheme)
        let before = try XCTUnwrap(TitleBarLayout(window), "the library's split view never appeared")

        for scheme in [started == .dark ? ColorScheme.light : .dark, started] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try waitUntilTaken(settings.settings.appearance, by: window, rendered: rendered, name: "macOS in \(scheme)")
            XCTAssertEqual(rendered.colorScheme, scheme, "the content didn't follow macOS to \(scheme)")
            try assertWindow(window, kept: before, switchingTo: "macOS in \(scheme)")
        }
    }

    /// Switches the language and the colour scheme live six times, as Settings does, and checks
    /// after each that the window kept its split view, its toolbar items and the sidebar's inset.
    /// Returns the layout the window started with.
    @discardableResult
    private func assertLiveSwitchesKeepTheTitleBar(
        of window: NSWindow,
        settings: SpotiglassSettingsStore,
        rendered: RenderedSettings
    ) throws -> TitleBarLayout {
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
            try waitUntilTaken(settings.settings.appearance, by: window, rendered: rendered, name: name)

            try assertWindow(window, kept: before, switchingTo: name)
        }
        return before
    }

    /// The window still has the split view and toolbar items it had, the toolbar's divider follows
    /// the split view, and the sidebar keeps its inset below the window buttons.
    private func assertWindow(_ window: NSWindow, kept before: TitleBarLayout, switchingTo name: String) throws {
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

    /// The main window's content, set up as the window scene sets it up, with Apple Music's
    /// library on screen from a stand-in source (no sign-in, no MusicKit, no network).
    private func hostMainWindow(
        settings: SpotiglassSettingsStore,
        services: MusicServiceStore,
        rendered: RenderedSettings
    ) async throws -> NSWindow {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        )
        let session = AppleMusicSession(authorization: LiveSettingsMusicAuthorization())
        await session.refresh()
        // A stand-in library, so the test never reads the Mac's own Apple Music library.
        let appleMusic = Self.standInLibrary()
        let spotifyHost = SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
            accessToken: "test", refreshedAccessToken: "test-refresh"
        ))
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: spotifyHost),
            serviceStore: services,
            appleMusicSession: session,
            appleMusicCatalog: { appleMusic }
        )
        .background(RenderedSettingsProbe(rendered: rendered))
        .environmentObject(auth)
        .environmentObject(settings)
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        .environmentObject(spotifyHost)
        .spotiglassLiveSettings(settings)
        return try showLikeTheMainWindow(root, settings: settings, rendered: rendered)
    }

    /// Spotify's library as the main window shows it to a signed-in account, and Apple Music's
    /// next to it, switched by the sidebar's service switcher. Both read from a stand-in API, the
    /// account's profile included, so nothing reaches Spotify or Apple Music.
    private func hostSignedInLibraries(
        settings: SpotiglassSettingsStore,
        rendered: RenderedSettings
    ) async throws -> (NSWindow, MusicServiceStore) {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.spotify, .appleMusic], active: .spotify
        ))
        let palette = CommandPaletteManager()
        let tokens = LiveSettingsSpotifyTokens()
        var libraries: [MusicService: AnyView] = [:]
        for service in [MusicService.spotify, .appleMusic] {
            let api = Self.standInLibrary()
            let browser = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
            await browser.load()
            libraries[service] = AnyView(PlaylistBrowserView(
                viewModel: browser,
                playbackHost: SpotiglassPlaybackHost(tokenProvider: tokens),
                catalogProvider: api,
                commandPaletteManager: palette,
                signOut: {},
                // Apple Music's library is set up as AppleMusicBrowserRoot sets it up.
                playbackMode: service == .appleMusic
                    ? .unavailable(SpotiglassL10n.string("error.playback.appleMusic.subscription.message"))
                    : .live,
                canDisconnect: service != .appleMusic,
                sidebarHeader: AnyView(MusicServiceSwitcher(
                    store: services, keymapStore: palette.keymapStore,
                    switchTo: { services.activate($0) }, add: { _ in }
                ))
            ))
        }
        let pins = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        // The stand-in API's account.
        pins.bind(userID: "u")
        let content = ActiveLibrary(services: services, libraries: libraries)
            // RootView gives every screen this space ahead of the library's own items.
            .toolbar { ToolbarSpacer(.flexible) }
            .background(RenderedSettingsProbe(rendered: rendered))
            .environmentObject(pins)
            .environmentObject(settings)
            .environmentObject(LyricsOverlayController())
            .spotiglassLiveSettings(settings)
        return (try showLikeTheMainWindow(content, settings: settings, rendered: rendered), services)
    }

    /// Two playlists and the account's profile, read from memory.
    private static func standInLibrary() -> MockBrowsingAPI {
        MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Night Drive"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Deep Focus"),
            ])],
            trackResults: [:]
        )
    }

    /// Hosts `content` in a window shaped like the main window and waits until it has drawn.
    private func showLikeTheMainWindow(
        _ content: some View,
        settings: SpotiglassSettingsStore,
        rendered: RenderedSettings
    ) throws -> NSWindow {
        let controller = ViewTestHost.host(content, size: CGSize(width: 1100, height: 700), measuresLayout: true)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = try XCTUnwrap(controller.view.window)
        // The app's window draws its content under the title bar, which is where the sidebar's
        // top inset comes from.
        window.styleMask.insert([.fullSizeContentView, .resizable, .miniaturizable])
        window.setContentSize(CGSize(width: 1100, height: 700))
        try waitUntilTaken(settings.settings.appearance, by: window, rendered: rendered, name: "the start")
        return window
    }

    /// Runs the main run loop until the window shows `appearance`, however long a busy machine
    /// takes: the content has drawn with the new language and colour scheme, the bar's Queue button
    /// reads in the new language, and the window has the new appearance. A fixed wait could look
    /// at the window before the switch reached it and pass without checking anything.
    private func waitUntilTaken(
        _ appearance: AppearanceSettings,
        by window: NSWindow,
        rendered: RenderedSettings,
        name: String
    ) throws {
        let queueLabel = SpotiglassL10n.string("browser.queue")
        let scheme = appearance.colorScheme.preferredColorScheme ?? Self.systemColorScheme
        let taken = AppKitTestSupport.pumpRunLoop(until: {
            rendered.language == appearance.language
                && rendered.settingsColorScheme == appearance.colorScheme
                && rendered.colorScheme == scheme
                && Self.colorScheme(of: window.effectiveAppearance) == scheme
                && TitleBarLayout(window)?.sidebarSeparator != nil
                && window.toolbar?.items.contains(where: { $0.label == queueLabel }) == true
        })
        let labels = window.toolbar?.items.map(\.label) ?? []
        XCTAssertTrue(taken, "the window never took \(name): toolbar labels \(labels), drawn with \(rendered.summary), window appearance \(String(describing: window.appearance?.name)), effective \(window.effectiveAppearance.name.rawValue), app \(NSApp.effectiveAppearance.name.rawValue) / \(String(describing: NSApp.appearance?.name))")
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// What a window that follows macOS gets: the app's own appearance.
    private static var systemColorScheme: ColorScheme {
        colorScheme(of: NSApp.effectiveAppearance)
    }

    private static func colorScheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// The active service's library, a new one for each service, as RootView shows them.
private struct ActiveLibrary: View {
    @ObservedObject var services: MusicServiceStore
    let libraries: [MusicService: AnyView]

    var body: some View {
        if let active = services.active, let library = libraries[active] {
            library.id(active)
        }
    }
}

/// What the main window's content last drew with, recorded from inside it.
@MainActor
private final class RenderedSettings {
    var language: AppLanguage?
    var settingsColorScheme: AppearanceColorScheme?
    var colorScheme: ColorScheme?

    var summary: String {
        "\(language?.rawValue ?? "nothing"), \(settingsColorScheme?.rawValue ?? "nothing"), \(String(describing: colorScheme))"
    }
}

/// Sits inside the window's content and records the settings and the colour scheme each time the
/// content draws, so a test can wait for a switch to reach it.
private struct RenderedSettingsProbe: View {
    @EnvironmentObject private var settings: SpotiglassSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    let rendered: RenderedSettings

    var body: some View {
        rendered.language = settings.settings.appearance.language
        rendered.settingsColorScheme = settings.settings.appearance.colorScheme
        rendered.colorScheme = colorScheme
        return Color.clear.frame(width: 0, height: 0)
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

private final class LiveSettingsSpotifyTokens: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "live-settings-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "live-settings-token" }
    func accessToken() async throws -> String { "live-settings-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "live-settings-token" }
}

private struct LiveSettingsMusicAuthorization: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status { .authorized }
    func requestAuthorization() async -> MusicAuthorization.Status { .authorized }
    func canPlayCatalogContent() async -> Bool? { false }
}
