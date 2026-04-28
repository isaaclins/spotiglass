import XCTest
@testable import Spotiglass

final class SpotiglassFoundationTests: XCTestCase {
    func testNotConfiguredStateCopyIsStable() {
        let state = AppConnectionState.signedOut

        XCTAssertEqual(state.title, "Spotify is not connected")
        XCTAssertEqual(
            state.message,
            "Enter your Spotify client ID, then connect your Spotify account."
        )
    }

    func testAppMetadataMatchesProjectIdentity() {
        XCTAssertEqual(AppMetadata.displayName, "Spotiglass")
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.isaaclins.spotiglass")
    }
}
