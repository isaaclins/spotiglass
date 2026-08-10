import XCTest

@testable import Spotiglass

@MainActor
final class SpotifyPlaybackWebViewCoordinatorTests: XCTestCase {
    func testTokenReplyReturnsAccessToken() async {
        let bridge = PlaybackTokenBridge(
            provider: MockPlaybackTokenProvider(accessToken: "live", refreshedAccessToken: "fresh")
        )
        let result = await SpotifyPlaybackWebViewCoordinatorDispatch.tokenReply(
            handlerName: SpotifyPlaybackWebViewCoordinatorDispatch.tokenHandlerName,
            body: ["refresh": false],
            refresh: false,
            tokenBridge: bridge
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.payload, ["accessToken": "live"])
    }

    func testTokenReplyUnsupportedHandlerName() async {
        let bridge = PlaybackTokenBridge(
            provider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b")
        )
        let result = await SpotifyPlaybackWebViewCoordinatorDispatch.tokenReply(
            handlerName: "other",
            body: [:],
            refresh: false,
            tokenBridge: bridge
        )
        XCTAssertNil(result.payload)
        XCTAssertEqual(result.error, "Unsupported token bridge message")
    }

    func testPlaybackEventDispatchesReady() {
        let event = SpotifyPlaybackWebViewCoordinatorDispatch.playbackEvent(
            body: ["name": "ready", "payload": ["deviceID": "dev-1"]]
        )
        guard case .ready(let deviceID) = event else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(deviceID, "dev-1")
    }

    func testPlaybackEventInvalidEnvelopeMapsToPlaybackError() {
        let event = SpotifyPlaybackWebViewCoordinatorDispatch.playbackEvent(body: ["bad": true])
        guard case .playbackError(let message) = event else {
            return XCTFail("expected playback error")
        }
        XCTAssertTrue(message.contains("Invalid playback bridge message"))
    }
}
