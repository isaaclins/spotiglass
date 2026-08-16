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
        ViewTestHost.assertFindLocalizedText("settings.account.connection", in: view)
        ViewTestHost.assertFindText("Spotify developer app", in: view)
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
}
