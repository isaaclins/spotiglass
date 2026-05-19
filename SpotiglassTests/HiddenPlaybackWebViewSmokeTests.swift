import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class HiddenPlaybackWebViewSmokeTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testHostedRepresentableBuildsWebView() {
        let commander = WebPlaybackViewCommander()
        let bridge = PlaybackTokenBridge(
            provider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b")
        )
        let coordinator = SpotifyPlaybackWebViewCoordinator(tokenBridge: bridge)
        let view = HiddenPlaybackWebView(commander: commander, coordinator: coordinator)
            .frame(width: 4, height: 4)
        ViewTestHost.host(view, size: CGSize(width: 8, height: 8))
        XCTAssertNotNil(commander)
    }
}
