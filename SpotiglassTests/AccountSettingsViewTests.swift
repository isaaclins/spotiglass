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

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Connection"))
        XCTAssertNoThrow(try inspected.find(text: "Spotify developer app"))
    }
}
