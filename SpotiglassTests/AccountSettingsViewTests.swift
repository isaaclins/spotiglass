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
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let view = AccountSettingsView(viewModel: viewModel)
        ViewTestHost.host(view)
        ViewTestHost.assertFindLocalizedText("settings.account.connection", in: view)
        ViewTestHost.assertFindText("Spotify developer app", in: view)
    }
}
