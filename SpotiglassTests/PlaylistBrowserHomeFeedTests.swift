import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserHomeFeedTests: XCTestCase {
    private func recentlyPlayedTrack(id: String, albumID: String, albumName: String) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: "Track \(id)",
            artists: ["Artist"],
            artistRefs: [SpotifyArtistRef(id: "ar", name: "Artist")],
            albumArtworkURL: nil,
            albumName: albumName,
            albumID: albumID,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    func testQuickAccessListsLikedSongsThenPlaylists() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"),
                PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two"),
            ])],
            trackResults: [:]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let cards = vm.homeQuickAccessCards
        XCTAssertEqual(cards.first?.destination, .likedSongs)
        XCTAssertEqual(cards.map(\.title), ["Liked Songs", "One", "Two"])
        XCTAssertEqual(cards.dropFirst().map(\.destination), [.playlist(id: "one"), .playlist(id: "two")])
    }

    func testHomeTopTrackOptionsUseTheRowTargetWithoutMove() throws {
        let track = TrackRowViewModel.numberedTopTracks([
            recentlyPlayedTrack(id: "home-track", albumID: "home-album", albumName: "Home Album")
        ])[0]
        let browserViewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        browserViewModel.detailState = .loaded(.home)
        let menu = TrackOpsMenuItems(
            targets: [track],
            browserViewModel: browserViewModel,
            sourcePlaylistID: nil
        )

        XCTAssertNoThrow(try menu.inspect().find(text: SpotiglassL10n.string("Add to playlist")))
        XCTAssertThrowsError(
            try menu.inspect().find(text: SpotiglassL10n.string("Move to playlist"))
        )
    }

    func testSelectingHomeLoadsTopTracksAndMarksHomeContent() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            [self.recentlyPlayedTrack(id: "t1", albumID: "al1", albumName: "Album 1")]
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.detailState, .loaded(.home))
        XCTAssertEqual(vm.homeTopTracks.value?.map(\.title), ["Track t1"])
        XCTAssertEqual(api.topTracksCallCount, 2)
    }

    func testManualHomeRefreshFetchesChangedSectionsOutsideFreshCache() async {
        let firstRecentlyPlayed = recentlyPlayedTrack(id: "recent-1", albumID: "album-1", albumName: "Album 1")
        let secondRecentlyPlayed = recentlyPlayedTrack(id: "recent-2", albumID: "album-2", albumName: "Album 2")
        let firstTopTrack = recentlyPlayedTrack(id: "top-1", albumID: "top-album-1", albumName: "Top Album 1")
        let secondTopTrack = recentlyPlayedTrack(id: "top-2", albumID: "top-album-2", albumName: "Top Album 2")
        var recentlyPlayedInvocation = 0
        var topTracksInvocation = 0
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")]),
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])
            ],
            trackResults: [:]
        )
        api.recentlyPlayedHandler = { _ in
            recentlyPlayedInvocation += 1
            return recentlyPlayedInvocation == 1 ? [firstRecentlyPlayed] : [secondRecentlyPlayed]
        }
        api.topTracksHandler = { _, _ in
            topTracksInvocation += 1
            return topTracksInvocation == 1 ? [firstTopTrack] : [secondTopTrack]
        }
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.unifiedRefreshMainSurface()

        XCTAssertEqual(viewModel.homeRecentlyPlayed.value?.map(\.id), ["album-2"])
        XCTAssertEqual(viewModel.homeTopTracks.value?.map(\.id), ["top-2"])
        XCTAssertEqual(api.recentlyPlayedCacheModes, [.freshOnly, .bypassCache])
        XCTAssertEqual(api.topTracksCacheModes, [.freshOnly, .bypassCache])
    }

    func testRecentlyPlayedDedupesByAlbum() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.recentlyPlayedHandler = { _ in
            [
                self.recentlyPlayedTrack(id: "t1", albumID: "al1", albumName: "Album 1"),
                self.recentlyPlayedTrack(id: "t2", albumID: "al1", albumName: "Album 1"),
                self.recentlyPlayedTrack(id: "t3", albumID: "al2", albumName: "Album 2"),
            ]
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.homeRecentlyPlayed.value?.map(\.id), ["al1", "al2"])
        XCTAssertEqual(
            vm.homeRecentlyPlayed.value?.first?.destination,
            .album(id: "al1", title: "Album 1", subtitle: "Artist", artworkURL: nil)
        )
    }

    func testSectionDegradesToUnavailableWhenScopeMissing() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            throw SpotifyAPIError.insufficientScope(requiredScopes: ["user-top-read"], message: nil, details: nil)
        }
        api.recentlyPlayedHandler = { _ in
            throw SpotifyAPIError.forbidden(message: nil, details: nil)
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.homeTopTracks, .unavailable)
        XCTAssertEqual(vm.homeRecentlyPlayed, .unavailable)
    }

    func testGreetingVariesByHour() {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        func date(hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        XCTAssertEqual(vm.homeGreeting(now: date(hour: 8)), "Good morning")
        XCTAssertEqual(vm.homeGreeting(now: date(hour: 14)), "Good afternoon")
        XCTAssertEqual(vm.homeGreeting(now: date(hour: 22)), "Good evening")
    }

    func testHomeGreetingUsesPageTitleStyleWhileSectionsUseSectionStyle() {
        let greeting = HomeSectionHeader(title: "Good morning", style: .pageTitle)
        let section = HomeSectionHeader(title: "Recently played")

        XCTAssertEqual(greeting.style, .pageTitle)
        XCTAssertEqual(section.style, .section)
        XCTAssertEqual(greeting.style.textStyle, .largeTitle)
        XCTAssertEqual(section.style.textStyle, .title2)
        XCTAssertEqual(greeting.style.font, .largeTitle.weight(.bold))
        XCTAssertEqual(section.style.font, .title2.weight(.bold))
    }
}
