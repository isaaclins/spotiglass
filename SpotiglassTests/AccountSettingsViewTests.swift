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

    /// Without Apple Music added, the section offers to add it instead.
    func testAppleMusicNotAddedOffersAdd() throws {
        let viewModel = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        let view = AccountSettingsView(
            viewModel: viewModel,
            serviceStore: store,
            appleMusicSession: AppleMusicSession()
        )
        ViewTestHost.host(view)

        ViewTestHost.assertFindLocalizedText("settings.account.appleMusic.status.notAdded", in: view)
        try view.inspect().find(button: SpotiglassL10n.string("settings.account.appleMusic.add")).tap()
        XCTAssertEqual(store.pendingAddition, .appleMusic)
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertEqual(store.services, [.spotify])
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
