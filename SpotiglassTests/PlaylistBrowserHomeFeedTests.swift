import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserHomeFeedTests: XCTestCase {
    private func recentlyPlayedTrack(id: String, albumID: String, albumName: String) -> MusicTrack {
        MusicTrack(
            id: id,
            name: "Track \(id)",
            artists: ["Artist"],
            artistRefs: [MusicArtistRef(id: "ar", name: "Artist")],
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

    /// Library rows outlive a language switch (the cache is fresh for 30 minutes), so the Home
    /// card must resolve my Apple Music library's "You" where it's shown, like the sidebar (#398).
    func testQuickAccessShowsMyLibraryOwnerInTheAppLanguage() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                MusicPlaylistSummary(
                    id: "p.mine", name: "Road", ownerID: AppleMusicBrowsingProvider.libraryUserID,
                    ownerName: "You", imageURL: nil, trackCount: 3, snapshotID: "applemusic"
                ),
                PlaylistBrowsingTestFixtures.playlist(id: "spotify", name: "Spotify"),
            ])],
            trackResults: [:]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-owner-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }

        XCTAssertEqual(vm.homeQuickAccessCards.dropFirst().map(\.subtitle), ["Du", "Owner"])
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
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))

        XCTAssertNoThrow(try menu.inspect().find(text: SpotiglassL10n.string("browser.addToPlaylist")))
        XCTAssertThrowsError(
            try menu.inspect().find(text: SpotiglassL10n.string("browser.moveToPlaylist"))
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!

        func greeting(_ hour: Int, _ minute: Int = 0) -> String {
            let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
            return vm.homeGreeting(now: date, calendar: calendar)
        }

        // #464: Home said "Good evening" at 03:31.
        XCTAssertEqual(greeting(3, 31), "Hello, night owl")
        XCTAssertEqual(greeting(0, 0), "Hello, night owl")
        XCTAssertEqual(greeting(4, 59), "Hello, night owl")
        XCTAssertEqual(greeting(5, 0), "Good morning")
        XCTAssertEqual(greeting(11, 59), "Good morning")
        XCTAssertEqual(greeting(12, 0), "Good afternoon")
        XCTAssertEqual(greeting(17, 59), "Good afternoon")
        XCTAssertEqual(greeting(18, 0), "Good evening")
        XCTAssertEqual(greeting(23, 59), "Good evening")
    }

    func testHomeGreetingScheduleWakesAtEachChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }

        // #464: Home opened at 23:00 and left on screen must change at midnight, then at 05:00.
        let entries = Array(HomeGreetingSchedule(calendar: calendar).entries(from: at(9, 23), mode: .normal).prefix(6))
        XCTAssertEqual(entries, [at(9, 23), at(10, 0), at(10, 5), at(10, 12), at(10, 18), at(11, 0)])

        // A change time itself moves on to the next one.
        XCTAssertEqual(PlaylistBrowserViewModel.nextHomeGreetingChange(after: at(10, 5), calendar: calendar), at(10, 12))

        let vm = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:]), cache: MockBrowsingCache())
        XCTAssertEqual(vm.homeGreeting(now: entries[0], calendar: calendar), "Good evening")
        XCTAssertEqual(vm.homeGreeting(now: entries[1], calendar: calendar), "Hello, night owl")
        XCTAssertEqual(vm.homeGreeting(now: entries[2], calendar: calendar), "Good morning")
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
