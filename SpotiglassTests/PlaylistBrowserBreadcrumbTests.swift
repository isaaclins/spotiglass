import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserBreadcrumbTests: XCTestCase {
    // MARK: - Breadcrumbs

    func testBreadcrumbSidebarLikedSongs() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.breadcrumbPath[0].systemImage, "heart.fill")
        guard case .likedSongs = viewModel.breadcrumbPath[0].kind else {
            return XCTFail("Expected likedSongs kind")
        }
    }

    func testBreadcrumbExtendFromLikedToArtistThenAlbum() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let albumTrack = SpotifyTrack(
            id: "alb-track-1",
            name: "Album Track 1",
            artists: ["Artist Name"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:alb-track-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            albumTracksHandler: { _, _, _ in [albumTrack] },
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(SidebarSelection.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: BrowserNavigationOrigin.extend, displayName: "Malcolm Todd")
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Sweet Boy",
            displaySubtitle: "Malcolm Todd",
            artworkURL: URL(string: "https://example.com/a.png"),
            origin: BrowserNavigationOrigin.extend
        )

        XCTAssertEqual(viewModel.breadcrumbPath.count, 3)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.breadcrumbPath[1].label, "Artist artist-xyz", "Artist load refines the crumb label from the mock API.")
        XCTAssertEqual(viewModel.breadcrumbPath[2].label, "Sweet Boy")
        XCTAssertEqual(viewModel.breadcrumbPath[2].systemImage, "opticaldisc")
    }

    func testBreadcrumbNavigateBackPopsLeafCrumb() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")

        XCTAssertEqual(viewModel.breadcrumbPath.count, 2)

        await viewModel.navigateBack()

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
    }

    func testBreadcrumbPaletteArtistResetReplacesTrail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-a", origin: .extend, displayName: "First")
        await viewModel.selectArtist(id: "artist-b", origin: .reset, displayName: "Second Artist")

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Artist artist-b", "Mock API artist name replaces the interim label.")
        guard case let .artist(id) = viewModel.breadcrumbPath[0].kind else {
            return XCTFail("Expected artist crumb")
        }
        XCTAssertEqual(id, "artist-b")
    }

    func testBreadcrumbJumpToBreadcrumbTrimsPrefix() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")

        await viewModel.jumpToBreadcrumb(at: 0)

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
        XCTAssertFalse(viewModel.canNavigateBack)
    }

    func testBreadcrumbJumpToHomeClearsTrailAndSelectsHome() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        await viewModel.jumpToHome()

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertFalse(viewModel.canNavigateBack)
    }

    func testBreadcrumbClearForSignOutEmptiesTrail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        viewModel.clearForSignOut()

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
    }

    func testBreadcrumbAfterPlaylistSwitchBackShowsPriorPlaylistTitle() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"), PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two")])],
            trackResults: [
                "one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        // Load now lands on Home, so select the first playlist explicitly before switching.
        await viewModel.selectPlaylist(id: "one")
        await viewModel.selectPlaylist(id: "two")
        XCTAssertEqual(viewModel.breadcrumbPath.last?.label, "Two")

        await viewModel.navigateBack()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath.last?.label, "One")
    }
}
