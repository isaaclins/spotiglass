import XCTest
@testable import Spotiglass

final class AppConnectionStateTests: XCTestCase {
    func testSignedOutCopy() {
        let state = AppConnectionState.signedOut
        XCTAssertEqual(state.title, "Spotify is not connected")
        XCTAssertTrue(state.message.contains("client ID"))
        XCTAssertFalse(state.isConnectedOrRefreshing)
    }

    func testSigningInCopy() {
        let state = AppConnectionState.signingIn
        XCTAssertEqual(state.title, "Opening Spotify sign-in")
        XCTAssertTrue(state.message.contains("127.0.0.1"))
        XCTAssertFalse(state.isConnectedOrRefreshing)
    }

    func testSignedInCopy() {
        let expires = Date(timeIntervalSince1970: 4_000_000)
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming",
            expiresAt: expires
        )
        let state = AppConnectionState.signedIn(session)
        XCTAssertEqual(state.title, "Spotify is connected")
        // The token expiry refreshes silently, so it is a diagnostic, not an
        // account fact the user should read here (#163).
        XCTAssertEqual(state.message, "Spotiglass is connected to your Spotify account.")
        XCTAssertFalse(state.message.lowercased().contains("token"))
        XCTAssertTrue(state.isConnectedOrRefreshing)
    }

    func testRefreshingCopy() {
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertEqual(AppConnectionState.refreshing(session).title, "Refreshing Spotify session")
        XCTAssertTrue(AppConnectionState.refreshing(nil).message.contains("refreshing"))
        XCTAssertTrue(AppConnectionState.refreshing(session).isConnectedOrRefreshing)
        XCTAssertTrue(AppConnectionState.refreshing(nil).isConnectedOrRefreshing)
    }

    func testFailedCopy() {
        let state = AppConnectionState.failed(AuthDisplayError(message: "Token expired"))
        XCTAssertEqual(state.title, "Spotify sign-in needs attention")
        XCTAssertEqual(state.message, "Token expired")
        XCTAssertFalse(state.isConnectedOrRefreshing)
    }
}
