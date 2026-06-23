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
        XCTAssertEqual(api.topTracksCallCount, 1)
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
}
