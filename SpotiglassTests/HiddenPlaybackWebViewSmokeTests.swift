import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class HiddenPlaybackWebViewSmokeTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testAppScopedHostRepresentableBuildsWebView() {
        let host = SpotiglassPlaybackHost(
            tokenProvider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b")
        )
        let view = SpotiglassPlaybackHostView(host: host)
            .frame(width: 4, height: 4)
        ViewTestHost.host(view, size: CGSize(width: 8, height: 8))
        XCTAssertNotNil(host.commander)
    }

    func testLegacyHostedRepresentableBuildsWebView() {
        let commander = WebPlaybackViewCommander()
        let coordinator = SpotifyPlaybackWebViewCoordinator(
            tokenBridge: PlaybackTokenBridge(
                provider: MockPlaybackTokenProvider(
                    accessToken: "a",
                    refreshedAccessToken: "b"
                )
            )
        )
        let view = HiddenPlaybackWebView(commander: commander, coordinator: coordinator)
            .frame(width: 4, height: 4)
        ViewTestHost.host(view, size: CGSize(width: 8, height: 8))
        XCTAssertNotNil(commander)
    }

    func testMultipleSceneContainersReuseAndTransferOneWebView() {
        let host = SpotiglassPlaybackHost(
            tokenProvider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b")
        )
        let first = SpotiglassPlaybackHostContainer(frame: .zero)
        let second = SpotiglassPlaybackHostContainer(frame: .zero)

        host.mount(first)
        host.mount(second)

        XCTAssertEqual(first.subviews.count, 1)
        XCTAssertTrue(second.subviews.isEmpty)

        host.unmount(first)

        XCTAssertTrue(first.subviews.isEmpty)
        XCTAssertEqual(second.subviews.count, 1)

        host.unmount(second)
        XCTAssertTrue(second.subviews.isEmpty)
    }
}
