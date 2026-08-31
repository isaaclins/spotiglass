import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
private struct LanguageKeyedPlaybackHostView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore
    let host: SpotiglassPlaybackHost

    var body: some View {
        SpotiglassPlaybackHostView(host: host)
            .id(settingsStore.settings.appearance.language.rawValue)
    }
}

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

    func testPlaybackStateSurvivesLanguageKeyedSceneReplacement() throws {
        let host = SpotiglassPlaybackHost(
            tokenProvider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b")
        )
        let playbackViewModel = host.playbackViewModel
        playbackViewModel.handle(.ready(deviceID: "device-1"))
        playbackViewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Track",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 12_000,
                uri: "spotify:track:1"
            ),
            isPaused: false,
            nextTracks: []
        ))
        let initialState = playbackViewModel.connectionState

        let settingsStore = try ViewTestHost.makeSettingsStore()
        let view = LanguageKeyedPlaybackHostView(settingsStore: settingsStore, host: host)
        ViewTestHost.host(view, size: CGSize(width: 8, height: 8))

        try settingsStore.mutate { $0.appearance.language = .german }
        AppKitTestSupport.pumpRunLoop()

        XCTAssertTrue(host.playbackViewModel === playbackViewModel)
        XCTAssertEqual(playbackViewModel.connectionState, initialState)
    }
}
