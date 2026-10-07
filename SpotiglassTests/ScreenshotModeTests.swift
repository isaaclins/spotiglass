import XCTest
@testable import Spotiglass

final class ScreenshotModeTests: XCTestCase {

    // MARK: - mockBaseURL(in:)

    func testInactiveWithoutEnvironmentVariable() {
        XCTAssertNil(ScreenshotMode.mockBaseURL(in: [:]))
    }

    func testAcceptsLoopbackHTTPAddresses() {
        XCTAssertEqual(
            ScreenshotMode.mockBaseURL(in: [ScreenshotMode.environmentKey: "http://127.0.0.1:43900"]),
            URL(string: "http://127.0.0.1:43900")
        )
        XCTAssertEqual(
            ScreenshotMode.mockBaseURL(in: [ScreenshotMode.environmentKey: "http://localhost:43900"]),
            URL(string: "http://localhost:43900")
        )
    }

    func testRejectsRemoteHostsAndOtherSchemes() {
        for raw in ["http://example.com:43900", "https://127.0.0.1:43900", "file:///tmp/mock", "", "not a url"] {
            XCTAssertNil(ScreenshotMode.mockBaseURL(in: [ScreenshotMode.environmentKey: raw]), raw)
        }
    }

    func testNormalLaunchUsesSpotify() {
        // The unit-test host is never launched with the variable set.
        XCTAssertFalse(ScreenshotMode.isActive)
        XCTAssertEqual(ScreenshotMode.accountsBaseURL.absoluteString, "https://accounts.spotify.com")
        XCTAssertEqual(ScreenshotMode.webAPIBaseURL.absoluteString, "https://api.spotify.com")
    }

    // MARK: - Base URLs

    func testBaseURLsFollowTheMock() {
        let mock = URL(string: "http://127.0.0.1:43900")!
        XCTAssertEqual(ScreenshotMode.accountsBaseURL(mockBase: mock), mock)
        XCTAssertEqual(ScreenshotMode.webAPIBaseURL(mockBase: mock), mock)
        XCTAssertEqual(
            ScreenshotMode.accountsBaseURL(mockBase: nil).appendingPathComponent("api/token").absoluteString,
            "https://accounts.spotify.com/api/token"
        )
    }

    // MARK: - inliningMockPlaybackSDK

    private let page = """
        <head><script src="https://sdk.scdn.co/spotify-player.js"></script></head>
        """

    func testLeavesPageAloneOutsideScreenshotMode() {
        var loaded = false
        let result = ScreenshotMode.inliningMockPlaybackSDK(into: page, mockBase: nil) { _ in
            loaded = true
            return Data()
        }
        XCTAssertEqual(result, page)
        XCTAssertFalse(loaded)
    }

    func testInlinesTheMockSDK() {
        var requested: URL?
        let result = ScreenshotMode.inliningMockPlaybackSDK(
            into: page,
            mockBase: URL(string: "http://127.0.0.1:43900")!
        ) { url in
            requested = url
            return Data("window.Spotify = {};".utf8)
        }
        XCTAssertEqual(requested?.absoluteString, "http://127.0.0.1:43900/sdk/spotify-player.js")
        XCTAssertEqual(result, "<head><script>window.Spotify = {};</script></head>")
    }

    func testKeepsPageWhenTheMockIsUnreachable() {
        let result = ScreenshotMode.inliningMockPlaybackSDK(
            into: page,
            mockBase: URL(string: "http://127.0.0.1:43900")!
        ) { _ in nil }
        XCTAssertEqual(result, page)
    }

    // MARK: - Seeded in-memory sign-in

    func testMemoryStoreCanStartWithTheScreenshotToken() throws {
        let store = MemoryOnlyRefreshTokenStore(refreshToken: ScreenshotMode.refreshToken)
        XCTAssertEqual(try store.loadRefreshToken(), "screenshot-mode")
    }
}
