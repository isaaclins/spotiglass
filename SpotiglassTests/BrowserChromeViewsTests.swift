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

    func testBreadcrumbToolbarEmptyPathShowsAppName() throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let view = BreadcrumbToolbarView(viewModel: viewModel)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 44))
        XCTAssertNoThrow(try view.inspect().find(text: AppMetadata.displayName))
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
        try view.inspect().find(text: AppMetadata.displayName).callOnTapGesture()
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
