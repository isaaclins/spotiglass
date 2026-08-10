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
            .environmentObject(LyricsOverlayController())
    }

    func testSignedOutShowsConnectChrome() throws {
        let auth = AuthViewModel(
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
}
