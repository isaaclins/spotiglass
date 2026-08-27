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
        RootView(commandPaletteManager: palette)
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
}
