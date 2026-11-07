import MusicKit
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class AccountSettingsViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testSignedOutShowsConnectionSection() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let view = AccountSettingsView(viewModel: viewModel)
        ViewTestHost.host(view)
        ViewTestHost.assertFindLocalizedText("service.spotify.name", in: view)
        ViewTestHost.assertFindText("Spotify developer app", in: view)
    }

    /// Each service signs in and out on its own (#373): with Apple Music added, the pane keeps
    /// Spotify's sign-in and adds an Apple Music section with its own Sign Out.
    func testEachServiceHasItsOwnSection() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .appleMusic)
        )
        let view = AccountSettingsView(
            viewModel: viewModel,
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        ViewTestHost.assertFindLocalizedText("service.spotify.name", in: view)
        ViewTestHost.assertFindLocalizedText("service.appleMusic.name", in: view)
        ViewTestHost.assertFindLocalizedText("settings.account.appleMusic.signOut", in: view)
        XCTAssertNoThrow(try view.inspect().find(SpotifyClientIDAndActionsView.self))
    }

    /// Signing out of Apple Music in Settings removes it from the service menu and hands the
    /// window to Spotify; Spotify's sign-in is not touched.
    func testAppleMusicSignOutRemovesOnlyAppleMusic() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .appleMusic)
        )
        var prepared = 0
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: { prepared += 1 },
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        try view.inspect()
            .find(button: SpotiglassL10n.string("settings.account.appleMusic.signOut"))
            .tap()

        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(store.services, [.spotify])
        XCTAssertEqual(store.active, .spotify)
    }

    /// Signing out of Apple Music while Spotify is on screen must leave Spotify's palette wired.
    /// It used to clear every window's palette (commands, sign-in state) and nothing on screen
    /// changed to wire it up again, so Refresh, Next Track and Open Search vanished from Spotify.
    func testAppleMusicSignOutOffScreenKeepsTheWindowWired() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .spotify)
        )
        let (registry, manager) = makeWiredScene()
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: { registry.resetTransientState() },
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        try view.inspect()
            .find(button: SpotiglassL10n.string("settings.account.appleMusic.signOut"))
            .tap()

        XCTAssertEqual(store.services, [.spotify])
        XCTAssertEqual(store.active, .spotify)
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertNotNil(manager.unifiedRefresh)
    }

    /// The same for Spotify: disconnecting it in Settings while Apple Music is on screen leaves
    /// Apple Music's palette alone.
    func testSpotifySignOutOffScreenKeepsTheWindowWired() throws {
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming",
            expiresAt: Date(timeIntervalSince1970: 4_000_000)
        )
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedIn(session)
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .appleMusic)
        )
        let (registry, manager) = makeWiredScene()
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: { registry.resetTransientState() },
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button")).tap()

        XCTAssertEqual(store.services, [.appleMusic])
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertNotNil(manager.unifiedRefresh)
    }

    /// A lapsed Spotify session keeps Spotify in the service menu. Disconnect used to need a live
    /// session, so Spotify could never be removed again without signing in first (#399).
    func testSignedOutSpotifyCanStillBeRemoved() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .spotify)
        )
        var prepared = 0
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: { prepared += 1 },
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button")).tap()

        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(store.services, [.appleMusic])
        XCTAssertEqual(store.active, .appleMusic)
    }

    /// Spotify on its own has nothing to fall back to, so a signed-out Disconnect stays off.
    func testSignedOutLoneSpotifyKeepsDisconnectOff() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        let view = AccountSettingsView(viewModel: viewModel, serviceStore: store)
        ViewTestHost.host(view)

        let disconnect = try view.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button"))
        XCTAssertTrue(disconnect.isDisabled())
    }

    /// A window whose palette is signed in and wired, as a browser leaves it.
    private func makeWiredScene() -> (SpotiglassSceneRegistry, CommandPaletteManager) {
        let scene = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let manager = scene.commandPaletteManager
        manager.isSignedIn = true
        manager.unifiedRefresh = {}
        return (registry, manager)
    }

    /// Without Apple Music added, the section offers to add it, and adding works right here: with
    /// every main window closed only Settings is open, and the addition used to wait forever for a
    /// window to ask for access and finish it. Like connecting Spotify here, the window doesn't move.
    func testAddAppleMusicFromSettingsWithNoWindow() async throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        let authorization = SettingsMusicAuthorization(answer: .authorized)
        let registry = SpotiglassSceneRegistry()
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: { registry.resetTransientState() },
            serviceStore: store,
            appleMusicSession: AppleMusicSession(authorization: authorization)
        )
        ViewTestHost.host(view)

        ViewTestHost.assertFindLocalizedText("settings.account.appleMusic.status.notAdded", in: view)
        try view.inspect().find(button: SpotiglassL10n.string("settings.account.appleMusic.add")).tap()
        try await waitUntil { store.isAdded(.appleMusic) }

        XCTAssertEqual(authorization.requests, 1, "Access is asked from Settings itself")
        XCTAssertTrue(store.isAdded(.appleMusic))
        XCTAssertNil(store.pendingAddition)
        XCTAssertEqual(store.active, .spotify)
    }

    /// Waits for the async work a tap starts (up to 5 s), instead of a fixed delay that a slow CI
    /// runner can outlast.
    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() {
            AppKitTestSupport.pumpRunLoop(for: 0.02)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Refusing access adds nothing and says it was refused.
    func testAddAppleMusicFromSettingsRefused() async throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        let session = AppleMusicSession(authorization: SettingsMusicAuthorization(answer: .denied))
        let view = AccountSettingsView(viewModel: viewModel, serviceStore: store, appleMusicSession: session)
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.string("settings.account.appleMusic.add")).tap()
        try await waitUntil { session.state == .denied }
        AppKitTestSupport.pumpRunLoop(for: 0.1)

        XCTAssertEqual(store.services, [.spotify])
        XCTAssertNil(store.pendingAddition)
        XCTAssertEqual(session.state, .denied)
        ViewTestHost.assertFindLocalizedText("settings.account.appleMusic.status.denied", in: view)
    }

    /// The token expiry is a diagnostic, not an account fact: it used to sit
    /// under Connection, where it duplicated the Status row and made a silently
    /// refreshing session look like it was about to break (#163).
    func testSignedInShowsTokenExpiryUnderDiagnosticsOnly() throws {
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming",
            expiresAt: Date(timeIntervalSince1970: 4_000_000)
        )
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedIn(session)
        )
        let view = AccountSettingsView(viewModel: viewModel)
        ViewTestHost.host(view)

        ViewTestHost.assertFindLocalizedText("settings.account.diagnostics.header", in: view)
        ViewTestHost.assertFindLocalizedText("settings.account.accessToken", in: view)
        // Connection keeps Status only; the details row is for the signed-out case.
        XCTAssertThrowsError(
            try view.inspect().find(text: SpotiglassL10n.string("settings.account.details"))
        )
    }

    func testSettingsSignOutRunsSceneCleanupBeforeAuthTransition() throws {
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming",
            expiresAt: Date(timeIntervalSince1970: 4_000_000)
        )
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedIn(session)
        )
        let scene = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        scene.commandPaletteManager.viewModel.show()
        scene.commandPaletteManager.viewModel.query = "stale query"
        scene.lyricsOverlayController.isPresented = true
        var cleanupCalled = false
        let view = AccountSettingsView(
            viewModel: viewModel,
            onSignOut: {
                cleanupCalled = true
                registry.resetTransientState()
            }
        )
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.string("auth.disconnect.button")).tap()

        XCTAssertTrue(cleanupCalled)
        XCTAssertFalse(scene.commandPaletteManager.viewModel.isPresented)
        XCTAssertEqual(scene.commandPaletteManager.viewModel.query, "")
        XCTAssertFalse(scene.lyricsOverlayController.isPresented)
    }
}

/// Apple Music access that hasn't been asked yet, and answers the request with `answer`.
private final class SettingsMusicAuthorization: AppleMusicAuthorizing, @unchecked Sendable {
    private let answer: MusicAuthorization.Status
    private var status: MusicAuthorization.Status = .notDetermined
    private(set) var requests = 0

    init(answer: MusicAuthorization.Status) {
        self.answer = answer
    }

    func currentStatus() -> MusicAuthorization.Status { status }
    func requestAuthorization() async -> MusicAuthorization.Status {
        requests += 1
        status = answer
        return answer
    }
    func canPlayCatalogContent() async -> Bool? { false }
}
