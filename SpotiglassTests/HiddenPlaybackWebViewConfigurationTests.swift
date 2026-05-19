import XCTest
import WebKit
@testable import Spotiglass

@MainActor
final class HiddenPlaybackWebViewConfigurationTests: XCTestCase {
    func testMakeRegistersHandlersAndNonPersistentStore() {
        let bridge = PlaybackTokenBridge(
            provider: MockPlaybackTokenProvider(accessToken: "tok", refreshedAccessToken: "tok2")
        )
        let coordinator = SpotifyPlaybackWebViewCoordinator(tokenBridge: bridge)
        let config = HiddenPlaybackWebViewConfiguration.make(coordinator: coordinator)
        XCTAssertEqual(config.websiteDataStore.isPersistent, false)
        XCTAssertFalse(config.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNotNil(config.userContentController)
    }

    func testHandlerNamesAreStable() {
        XCTAssertEqual(HiddenPlaybackWebViewConfiguration.playbackHandlerName, "spotiglassPlayback")
        XCTAssertEqual(HiddenPlaybackWebViewConfiguration.tokenHandlerName, "spotiglassToken")
    }
}
