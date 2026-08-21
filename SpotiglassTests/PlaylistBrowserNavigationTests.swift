import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserNavigationTests: XCTestCase {

    func testSelectArtistClearsPlaylistSelectionAndShowsArtistDetail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [PlaylistBrowsingTestFixtures.fallbackTrack(id: "hit", name: "Hit", artistId: "artist-xyz")],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        XCTAssertEqual(viewModel.sidebarSelection, .home)

        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
        XCTAssertEqual(detail.artist.name, "Artist artist-xyz")
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.title, "Hit")
    }

    func testDirectArtistDrillInClearsSelectionBeforeMatchingRowsCanBeTargeted() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "same-id")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [PlaylistBrowsingTestFixtures.fallbackTrack(id: "same-id", name: "Artist Match", artistId: "artist-xyz")],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        viewModel.selectedDetailTrackIDs = ["same-id"]
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertTrue(viewModel.selectedDetailTrackIDs.isEmpty)
        XCTAssertEqual(viewModel.loadedContextTracksForPalette?.map(\.id), ["same-id"])
        XCTAssertTrue(viewModel.selectedTrackRows.isEmpty)
    }

    func testBackNavigationTracksPlaylistHistory() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"), PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two")])],
            trackResults: [
                "one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        XCTAssertFalse(viewModel.canNavigateBack)
        XCTAssertEqual(viewModel.sidebarSelection, .home)

        await viewModel.selectPlaylist(id: "two")
        XCTAssertTrue(viewModel.canNavigateBack)
        XCTAssertEqual(viewModel.selectedPlaylistID, "two")

        // Back from the first explicit selection returns to the Home landing surface.
        await viewModel.navigateBack()
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertNil(viewModel.selectedPlaylistID)
        XCTAssertFalse(viewModel.canNavigateBack)
        XCTAssertEqual(viewModel.detailState, .loaded(.home))
    }

    func testSelectAlbumLoadsAlbumAsPlaylistStyleDetail() async {
        let albumCoverURL = URL(string: "https://example.com/cover.png")
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
            albumTracksHandler: { _, _, _ in [albumTrack] }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Album Name",
            displaySubtitle: "Artist Name",
            artworkURL: albumCoverURL
        )

        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected album detail to render through playlist-style content.")
        }
        XCTAssertEqual(detail.playlist.id, "album-123")
        XCTAssertEqual(detail.playlist.title, "Album Name")
        XCTAssertEqual(detail.playlist.owner, "Artist Name")
        XCTAssertEqual(detail.tracks.map(\.title), ["Album Track 1"])
        XCTAssertEqual(detail.tracks.first?.artworkURL, albumCoverURL)
        XCTAssertEqual(api.albumTracksCallCount, 1, "Album detail should reuse the already-fetched album cover locally, without extra Spotify calls.")
        XCTAssertEqual(api.searchCallCount, 0)
    }

    func testDirectAlbumDrillInClearsSelectionBeforeMatchingRowsCanBeTargeted() async {
        let albumTrack = SpotifyTrack(
            id: "same-id",
            name: "Album Match",
            artists: ["Artist Name"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:same-id"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            albumTracksHandler: { _, _, _ in [albumTrack] }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        viewModel.selectedDetailTrackIDs = ["same-id"]
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Album Name",
            displaySubtitle: "Artist Name",
            artworkURL: nil
        )

        XCTAssertTrue(viewModel.selectedDetailTrackIDs.isEmpty)
        XCTAssertTrue(viewModel.selectedTrackRows.isEmpty)
    }

    func testBackNavigationReturnsFromAlbumToArtist() async {
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
            albumTracksHandler: { _, _, _ in [albumTrack] }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Album Name",
            displaySubtitle: "Artist Name",
            artworkURL: URL(string: "https://example.com/cover.png")
        )
        XCTAssertTrue(viewModel.canNavigateBack)
        guard case let .loaded(.playlist(albumDetail)) = viewModel.detailState else {
            return XCTFail("Expected album detail before back navigation.")
        }
        XCTAssertEqual(albumDetail.playlist.id, "album-123")

        await viewModel.navigateBack()
        XCTAssertTrue(viewModel.canNavigateBack)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected artist detail after navigating back from album.")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
    }

    func testAlbumCardTapRouterSingleTapOpensAndDoubleTapCancelsPendingSingle() async {
        let router = AlbumCardTapRouter(doubleClickDelayNanoseconds: 20_000_000)
        var openedIDs: [String] = []
        var openAndPlayCount = 0

        router.handleSingleTap(albumID: "album-1") {
            openedIDs.append("album-1")
        }
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(openedIDs, ["album-1"])

        router.handleSingleTap(albumID: "album-2") {
            openedIDs.append("album-2")
        }
        router.handleDoubleTap {
            openedIDs.append("album-2")
            openAndPlayCount += 1
        }
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(openAndPlayCount, 1)
        XCTAssertEqual(openedIDs.filter { $0 == "album-2" }.count, 1, "Double-tap should cancel pending single-tap open.")
    }

    func testCommandPaletteContextEligibleWhenArtistDetailLoaded() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [PlaylistBrowsingTestFixtures.fallbackTrack(id: "hit", name: "Hit", artistId: "artist-xyz")],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertTrue(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertEqual(viewModel.loadedContextTracksForPalette?.map(\.title), ["Hit"])
    }

    func testCommandPaletteContextEligibleWhenPlaylistDetailLoaded() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "one")

        XCTAssertTrue(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertEqual(viewModel.loadedContextTracksForPalette?.map(\.title), ["Track track-one"])
    }

    func testCommandPaletteContextNotEligibleWhenSidebarHome() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.home)

        XCTAssertFalse(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertNil(viewModel.loadedContextTracksForPalette)
    }

    /// Mirrors `List` + `.onChange(of: sidebarSelection)` calling `selectPlaylist(nil)` after `selectArtist` clears sidebar selection.
    func testSelectArtistSurvivesSubsequentSelectPlaylistNilFromSidebarOnChange() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectPlaylist(id: nil)

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail after simulated onChange(nil)")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
    }
}
