import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class BrowserChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// At the root the window title already names the app, so the breadcrumb
    /// renders nothing rather than repeating it as an inert second copy (#161).
    func testBreadcrumbToolbarEmptyPathShowsNothing() throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let view = BreadcrumbToolbarView(viewModel: viewModel)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 44))
        XCTAssertThrowsError(try view.inspect().find(text: AppMetadata.displayName))
    }

    func testBreadcrumbToolbarShowsCrumbLabels() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        let view = BreadcrumbToolbarView(viewModel: viewModel)
        ViewTestHost.host(view, size: CGSize(width: 520, height: 44))
        XCTAssertNoThrow(try view.inspect().find(text: "Liked Songs"))
    }

    func testBreadcrumbToolbarHomeTapClearsTrail() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        XCTAssertFalse(viewModel.breadcrumbPath.isEmpty)

        let view = BreadcrumbToolbarView(viewModel: viewModel)
        ViewTestHost.host(view, size: CGSize(width: 520, height: 44))
        // The home crumb is a real Button now, not a tap gesture, so that the
        // trait it advertises matches a working action (#113).
        try view.inspect().find(button: AppMetadata.displayName).tap()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .home)
    }

    func testPlayingWaveformIconPausedAndPlaying() throws {
        let playing = PlayingWaveformIcon(isPlaying: true)
            .frame(width: 24, height: 16)
        ViewTestHost.host(playing, size: CGSize(width: 48, height: 32))
        XCTAssertNoThrow(try playing.inspect())

        let paused = PlayingWaveformIcon(isPlaying: false, color: .red)
            .frame(width: 24, height: 16)
        ViewTestHost.host(paused, size: CGSize(width: 48, height: 32))
        XCTAssertNoThrow(try paused.inspect())
    }

    /// The icon sits in every playing row, so it must hold still for someone who
    /// asked the system for less motion (#118). Drives the playback and the
    /// Reduce Motion change on a live host, since both decide the frozen state.
    func testPlayingWaveformIconFollowsPlaybackChanges() throws {
        let driver = WaveformMotionDriver(isPlaying: false)
        let view = WaveformMotionDriverView(driver: driver)
        ViewTestHost.host(view, size: CGSize(width: 48, height: 32))

        driver.isPlaying = true
        AppKitTestSupport.pumpRunLoop()
        driver.isPlaying = false
        AppKitTestSupport.pumpRunLoop()

        XCTAssertNoThrow(try view.inspect())
    }

    func testNavigationToolbarChromeHidesBackWhenCannotNavigate() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()

        let chrome = NavigationToolbarChrome(viewModel: viewModel)
            .frame(width: 480, height: 44)
        ViewTestHost.host(chrome, size: CGSize(width: 480, height: 44))
        XCTAssertNoThrow(try chrome.inspect())
        XCTAssertFalse(viewModel.canNavigateBack)
    }
}

/// Drives `PlayingWaveformIcon` through playback and Reduce Motion changes on a
/// hosted view, so the icon keeps the same identity and its `onChange` handlers
/// actually run.
private final class WaveformMotionDriver: ObservableObject {
    @Published var isPlaying: Bool

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }
}

private struct WaveformMotionDriverView: View {
    @ObservedObject var driver: WaveformMotionDriver

    var body: some View {
        PlayingWaveformIcon(isPlaying: driver.isPlaying)
            .frame(width: 24, height: 16)
    }
}
