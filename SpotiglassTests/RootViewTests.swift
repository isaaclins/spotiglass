import MusicKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class RootViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makeRootView(
        auth: AuthViewModel,
        palette: CommandPaletteManager
    ) throws -> some View {
        let tokens = MockPlaybackTokenProvider(accessToken: "test", refreshedAccessToken: "test-refresh")
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        return RootView(commandPaletteManager: palette, playbackHost: playbackHost)
            .environmentObject(try ViewTestHost.makeSettingsStore())
            .environmentObject(auth)
            .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
    }

    func testSignedOutShowsConnectChrome() throws {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        auth.clientID = "test-client"
        let palette = CommandPaletteManager()
        let view = try makeRootView(auth: auth, palette: palette)
        ViewTestHost.host(view, size: CGSize(width: 720, height: 520))
        XCTAssertNoThrow(try view.inspect().find(text: "Connect Spotify"))
        XCTAssertFalse(palette.isSignedIn)
    }

    func testOnAppearWiresPaletteManagerCallbacks() throws {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let palette = CommandPaletteManager()
        let view = try makeRootView(auth: auth, palette: palette)
        ViewTestHost.host(view, size: CGSize(width: 400, height: 300))
        _ = view
        XCTAssertNotNil(palette.signOut)
        XCTAssertNotNil(palette.openSettings)
    }

    func testSceneTeardownDetachesOnlyTheCurrentHost() {
        let first = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        let second = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        let registry = SpotiglassSceneRegistry()
        registry.activate(first)
        registry.activate(second)
        first.commandPaletteManager.viewModel.show()
        second.commandPaletteManager.viewModel.show()
        first.lyricsOverlayController.isPresented = true
        second.lyricsOverlayController.isPresented = true

        // Closing an inactive scene must not run teardown against it. Its
        // controller is already isolated, and the active scene keeps its state.
        registry.deactivate(first)

        XCTAssertTrue(first.commandPaletteManager.viewModel.isPresented)
        XCTAssertTrue(first.lyricsOverlayController.isPresented)
        XCTAssertTrue(second.commandPaletteManager.viewModel.isPresented)
        XCTAssertTrue(second.lyricsOverlayController.isPresented)
        XCTAssertTrue(registry.activeScene === second)

        // The current host is the only one whose transient state is detached.
        registry.deactivate(second)

        XCTAssertFalse(second.commandPaletteManager.viewModel.isPresented)
        XCTAssertFalse(second.lyricsOverlayController.isPresented)
        XCTAssertNil(registry.activeScene)
    }

    func testSignOutCallbackHidesPaletteBeforeAuthTransition() throws {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedOut
        )
        let palette = CommandPaletteManager()
        let view = try makeRootView(auth: auth, palette: palette)
        ViewTestHost.host(view, size: CGSize(width: 400, height: 300))

        palette.viewModel.show()
        palette.viewModel.query = "stale query"
        palette.signOut?()

        XCTAssertFalse(palette.viewModel.isPresented)
        XCTAssertEqual(palette.viewModel.query, "")
    }

    /// Spotify's player starts new music only while Spotify is on screen (#373): the window keeps
    /// the app-wide player's gate in step with the service on screen, from the first frame on.
    func testSpotifyPlayerOnlyStartsMusicInTheSpotifySpace() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic, .spotify], active: .appleMusic
        ))
        let session = AppleMusicSession(authorization: DeniedMusicAuthorization())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
            accessToken: "test", refreshedAccessToken: "test-refresh"
        ))
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: playbackHost),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        ))
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(root)
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        XCTAssertTrue(playbackHost.playbackViewModel.refusesNewPlayback)

        services.activate(.spotify)
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        XCTAssertFalse(playbackHost.playbackViewModel.refusesNewPlayback)

        services.activate(.appleMusic)
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        XCTAssertTrue(playbackHost.playbackViewModel.refusesNewPlayback)
    }

    /// Spotify's sign-in screen after its session lapsed, with Apple Music added too: Disconnect
    /// takes Spotify out of the service menu and hands the window to Apple Music (#399). On its own,
    /// Spotify keeps Disconnect off.
    func testSignInScreenDisconnectRemovesALapsedSpotify() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic, .spotify], active: .spotify
        ))
        let session = AppleMusicSession(authorization: DeniedMusicAuthorization())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
                accessToken: "test", refreshedAccessToken: "test-refresh"
            ))),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedOut
        ))
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(root, size: CGSize(width: 720, height: 520))
        AppKitTestSupport.pumpRunLoop(for: 0.1)

        try root.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button")).tap()
        AppKitTestSupport.pumpRunLoop(for: 0.1)

        XCTAssertEqual(services.services, [.appleMusic])
        XCTAssertEqual(services.active, .appleMusic)

        let lone = try makeRootView(
            auth: AuthViewModel(
                settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
                refreshTokenStore: MemoryOnlyRefreshTokenStore(),
                initialState: .signedOut
            ),
            palette: CommandPaletteManager()
        )
        ViewTestHost.host(lone, size: CGSize(width: 720, height: 520))
        XCTAssertTrue(try lone.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button")).isDisabled())
    }

    /// Disconnect Spotify in Settings while Apple Music is on screen, then add Spotify again before
    /// the sign-out has finished clearing caches. The saved sign-in is already deleted, so adding
    /// must wait for a fresh sign-in instead of taking the session that is being torn down.
    func testReaddingSpotifyDuringSignOutRequiresFreshSignIn() async throws {
        let cleanupStarted = AsyncSignal()
        let finishCleanup = AsyncSignal()
        let tokens = MemoryOnlyRefreshTokenStore(refreshToken: "old-refresh")
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: tokens,
            signOutDataCleaner: {},
            artworkCacheClearer: {
                cleanupStarted.signal()
                await finishCleanup.wait()
            },
            initialState: .signedIn(AuthenticatedSession(
                accessToken: "old-access", tokenType: "Bearer", scope: "", expiresAt: .distantFuture
            ))
        )
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic], active: .appleMusic
        ))
        let session = AppleMusicSession(authorization: DeniedMusicAuthorization())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
                accessToken: "test", refreshedAccessToken: "test-refresh"
            ))),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(auth)
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(root)

        // Spotify connected from Settings: added without moving the window.
        services.completeAddition(of: .spotify)
        // Settings' Disconnect removes the space, then signs out asynchronously.
        services.signOutRemoving(.spotify)
        let signingOut = Task { await auth.signOut() }
        await cleanupStarted.wait()
        XCTAssertNil(try tokens.loadRefreshToken())
        XCTAssertTrue(auth.isSigningOut)

        services.beginAddition(of: .spotify)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(services.isAdded(.spotify), "Deleted credentials must require a fresh sign-in")
        XCTAssertEqual(services.pendingAddition, .spotify)

        finishCleanup.signal()
        await signingOut.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(auth.isSigningOut)
        XCTAssertFalse(services.isAdded(.spotify))
        XCTAssertEqual(services.pendingAddition, .spotify)
    }

    // MARK: - The palette is modal for VoiceOver (#501)

    /// Opens the palette over `root` and checks that VoiceOver reaches only the palette, then
    /// closes it and checks the page comes back. With `typingInPage`, the page's text field is
    /// being edited when the palette opens and must be again after esc.
    private func assertPaletteIsModal(
        over root: some View,
        palette paletteOfWindow: () -> CommandPaletteManager?,
        pageElement: String,
        typingInPage: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let controller = ViewTestHost.host(root, size: CGSize(width: 900, height: 640))
        let window = try XCTUnwrap(controller.view.window)
        AppKitTestSupport.activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        let palette = try XCTUnwrap(paletteOfWindow(), file: file, line: line)
        let fieldPlaceholder = SpotiglassL10n.format(
            "palette.searchPlaceholder.songs.all", MusicServiceSelection.current.displayName
        )
        let mentions = { (elements: [String], text: String) in elements.contains { $0.contains(text) } }

        let before = try AppKitTestSupport.settledAccessibilityElements(in: window) { mentions($0, pageElement) }
        XCTAssertTrue(mentions(before, pageElement), "The page should be reachable: \(before)", file: file, line: line)
        var pageField: NSTextField?
        if typingInPage {
            let field = try XCTUnwrap(firstTextField(in: controller.view), "The page has no text field", file: file, line: line)
            XCTAssertTrue(AppKitTestSupport.makeFirstResponder(field, in: window), file: file, line: line)
            XCTAssertTrue(isEditing(field, in: window), "The page's field should be focused", file: file, line: line)
            pageField = field
        }
        let pageFocus = window.firstResponder

        palette.viewModel.show()
        let open = try AppKitTestSupport.settledAccessibilityElements(in: window) {
            mentions($0, fieldPlaceholder) && !mentions($0, pageElement)
        }
        XCTAssertTrue(mentions(open, fieldPlaceholder), "The palette's field should be reachable: \(open)", file: file, line: line)
        XCTAssertFalse(
            mentions(open, pageElement),
            "VoiceOver still reaches the page behind the palette: \(open)",
            file: file,
            line: line
        )

        palette.viewModel.hide()
        let after = try AppKitTestSupport.settledAccessibilityElements(in: window) {
            mentions($0, pageElement) && !mentions($0, fieldPlaceholder)
        }
        XCTAssertTrue(mentions(after, pageElement), "The page should be back after esc: \(after)", file: file, line: line)
        XCTAssertFalse(mentions(after, fieldPlaceholder), "The palette should be gone: \(after)", file: file, line: line)
        if let pageField {
            XCTAssertTrue(
                isEditing(pageField, in: window),
                "The page's field should have focus again, not \(String(describing: window.firstResponder))",
                file: file,
                line: line
            )
        } else {
            XCTAssertTrue(window.firstResponder === pageFocus, "Focus should return to where it was", file: file, line: line)
        }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    /// A field being edited hands first responder to the window's field editor.
    private func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
        window.firstResponder === field || (window.firstResponder as? NSTextView)?.delegate === field
    }

    func testPaletteHidesTheSpotifyPageFromVoiceOver() throws {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        auth.clientID = "test-client"
        let palette = CommandPaletteManager()
        try assertPaletteIsModal(
            over: try makeRootView(auth: auth, palette: palette),
            palette: { palette },
            pageElement: SpotiglassL10n.string("auth.clientID.label"),
            typingInPage: true
        )
    }

    func testPaletteHidesTheAppleMusicPageFromVoiceOver() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic], active: .appleMusic
        ))
        let session = AppleMusicSession(authorization: DeniedMusicAuthorization())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let registry = SpotiglassSceneRegistry()
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: registry,
            playbackHosts: .forTests(spotify: SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
                accessToken: "test", refreshedAccessToken: "test-refresh"
            ))),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        ))
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        try assertPaletteIsModal(
            over: root,
            palette: { registry.activeScene?.commandPaletteManager },
            pageElement: SpotiglassL10n.string("appleMusic.permission.openSettings")
        )
    }
}

private struct DeniedMusicAuthorization: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status { .denied }
    func requestAuthorization() async -> MusicAuthorization.Status { .denied }
    func canPlayCatalogContent() async -> Bool? { false }
}

private struct GrantedMusicAuthorization: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status { .authorized }
    func requestAuthorization() async -> MusicAuthorization.Status { .authorized }
    func canPlayCatalogContent() async -> Bool? { false }
}

/// Adding a service puts its library on screen before the addition finishes. Finishing it must not
/// clear the pins that library's browser just bound: Apple Music added from "Add a service…" used
/// to show no pins at all, and every pin made before the next switch was never saved.
@MainActor
final class RootViewPinsAfterAddingTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func hostRoot(services: MusicServiceStore) async throws -> PinnedItemsStore {
        let cache = InMemoryPinnedItemsCache()
        try cache.savePinnedItems(
            [PinnedItem(
                id: "album:l.saved", kind: .album, title: "Saved Album", subtitle: "A",
                artworkURL: nil, spotifyURI: nil, isStale: false
            )],
            userID: AppleMusicBrowsingProvider.libraryUserID
        )
        let pinned = PinnedItemsStore(cache: cache)
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        )
        let session = AppleMusicSession(authorization: GrantedMusicAuthorization())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: SpotiglassSceneRegistry(),
            playbackHosts: .forTests(spotify: SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
                accessToken: "test", refreshedAccessToken: "test-refresh"
            ))),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(auth)
        .environmentObject(pinned)
        ViewTestHost.host(root, size: CGSize(width: 1100, height: 700))
        return pinned
    }

    private func settle(until done: () -> Bool = { false }, rounds: Int = 40) async throws {
        for _ in 0..<rounds {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
            try await Task.sleep(for: .milliseconds(50))
            if done() { break }
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
    }

    func testAddingAppleMusicShowsItsPins() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify))
        let pinned = try await hostRoot(services: services)

        services.beginAddition(of: .appleMusic)
        try await settle(until: { pinned.boundUserID != nil })

        XCTAssertTrue(services.isAdded(.appleMusic))
        XCTAssertNil(services.pendingAddition)
        XCTAssertEqual(pinned.boundUserID, AppleMusicBrowsingProvider.libraryUserID)
        XCTAssertEqual(pinned.items.map(\.id), ["album:l.saved"])
    }

    func testPinMadeRightAfterAddingAppleMusicIsKept() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify))
        let pinned = try await hostRoot(services: services)
        services.beginAddition(of: .appleMusic)
        try await settle(until: { pinned.boundUserID != nil })

        pinned.pin(PinnedItem(
            id: "album:l.new", kind: .album, title: "Pinned After Adding", subtitle: "B",
            artworkURL: nil, spotifyURI: nil, isStale: false
        ))
        services.activate(.spotify)
        try await settle(rounds: 10)
        services.activate(.appleMusic)
        try await settle(until: { pinned.items.count == 2 }, rounds: 20)

        XCTAssertEqual(pinned.items.map(\.id), ["album:l.saved", "album:l.new"])
    }
}

extension SpotiglassPlaybackHosts {
    /// View tests: the given player is Spotify's; Apple Music's is made on first use.
    @MainActor
    static func forTests(spotify: SpotiglassPlaybackHost) -> SpotiglassPlaybackHosts {
        SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider())
        }
    }
}
