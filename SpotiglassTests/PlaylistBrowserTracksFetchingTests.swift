import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserTracksFetchingTests: XCTestCase {

    func testReselectingPlaylistWithinCooldownSkipsSecondItemsFetch() async {
        let snapshot = "snapshot-stable"
        let playlistA = PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [.success([PlaylistBrowsingTestFixtures.track(id: "ta")])],
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])],
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        // Load lands on Home, so select the first playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)
        await viewModel.selectPlaylist(id: "b")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"], 1)
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(
            api.playlistTracksInvocationCountByID["a"], 1,
            "Cooldown should skip a second `/items` fetch for the same playlist snapshot.")
    }

    func testReselectingPlaylistAfterCooldownRefetchesItems() async {
        let snapshot = "snapshot-stable"
        let playlistA = PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [
                    .success([PlaylistBrowsingTestFixtures.track(id: "ta")]),
                    .success([PlaylistBrowsingTestFixtures.track(id: "ta2")]),
                ],
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])],
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        // Load lands on Home, so select the first playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)
        await viewModel.selectPlaylist(id: "b")
        clock = start.addingTimeInterval(31)
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 2)
    }

    func testPlaylistSnapshotRotationForcesItemsRefetchEvenWithinCooldown() async {
        let s1 = "snap-1"
        let s2 = "snap-2"
        let playlistOneV1 = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: s1)
        let playlistTwo = PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two", snapshotID: s1)
        let playlistOneV2 = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: s2)
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([playlistOneV1, playlistTwo]),
                .success([playlistOneV2, playlistTwo]),
            ],
            trackResults: [
                "one": [
                    .success([PlaylistBrowsingTestFixtures.track(id: "t1")]),
                    .success([PlaylistBrowsingTestFixtures.track(id: "t2")]),
                ],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "u1")])],
            ]
        )
        let cache = MockBrowsingCache()
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            tracksRevalidateMinInterval: 300
        )

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.selectPlaylist(id: "one")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshPlaylists(trigger: .automatic)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 2)
    }

    func testRefreshPlaylistsWithUnchangedSnapshotDoesNotRefetchSelectedTracks() async {
        let snapshot = "snap-unchanged"
        let playlistOne = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistOne]), .success([playlistOne])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        // Load lands on Home, so select the playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "one")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshPlaylists(trigger: .automatic)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
    }

    func testExplicitRefreshBypassesTracksCooldown() async {
        let snapshot = "snap"
        let playlistOne = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistOne])],
            trackResults: [
                "one": [
                    .success([PlaylistBrowsingTestFixtures.track(id: "a")]),
                    .success([PlaylistBrowsingTestFixtures.track(id: "b")]),
                ]
            ]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache, tracksRevalidateMinInterval: 300)

        await viewModel.load()
        // Load lands on Home, so select the playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "one")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshSelectedPlaylist()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 2)
    }

    func testRapidPlaylistSelectionCancelsInflightItemsFetch() async {
        let snapshot = "snap"
        let playlistA = PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [.success([PlaylistBrowsingTestFixtures.track(id: "ta")])],
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])],
            ]
        )
        api.playlistTracksDelayOnInvocation = 400_000_000
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        // Load lands on Home, so select the first playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)

        let firstSwitch = Task { await viewModel.selectPlaylist(id: "b") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await viewModel.selectPlaylist(id: "a")
        await firstSwitch.value

        XCTAssertEqual(
            api.playlistTracksInvocationCountByID["a"], 1, "Cancelled in-flight fetch for B should not complete.")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
    }

    func testForbiddenTracksOnFollowedPlaylistShowsLockedState() async {
        // The mock profile id is "u"; the fixture playlist's ownerID is "owner-id",
        // so the playlist is followed (non-owned) and a 403 must produce the locked state.
        let followed = PlaylistBrowsingTestFixtures.playlist(
            id: "followed", name: "Someone Else's Mix", snapshotID: "snap")
        let api = MockBrowsingAPI(
            playlistResults: [.success([followed])],
            trackResults: [
                "followed": [.failure(SpotifyAPIError.forbidden(message: "Forbidden", details: nil))]
            ]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        await viewModel.selectPlaylist(id: "followed")

        guard case .error(let displayError) = viewModel.detailState else {
            return XCTFail("Expected a terminal error state, got \(viewModel.detailState)")
        }
        XCTAssertNotNil(displayError.lockedPlaylist)
        XCTAssertEqual(displayError.lockedPlaylist?.playlistID, "followed")
        XCTAssertEqual(displayError.lockedPlaylist?.contextURI, "spotify:playlist:followed")
        XCTAssertFalse(displayError.canRetry)
    }

    func testForbiddenTracksOnOwnedPlaylistDoesNotShowLockedState() async {
        // Playlist owned by the current user ("u") should fall through to the
        // generic error mapping, never the followed-playlist locked state.
        let owned = SpotifyPlaylistSummary(
            id: "mine",
            name: "My Mix",
            ownerID: "u",
            ownerName: "Me",
            imageURL: nil,
            trackCount: 1,
            snapshotID: "snap"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([owned])],
            trackResults: [
                "mine": [.failure(SpotifyAPIError.forbidden(message: "Forbidden", details: nil))]
            ]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        await viewModel.selectPlaylist(id: "mine")

        guard case .error(let displayError) = viewModel.detailState else {
            return XCTFail("Expected a terminal error state, got \(viewModel.detailState)")
        }
        XCTAssertNil(displayError.lockedPlaylist)
    }

    func testDoubleArrowNextDebouncesToSingleItemsFetch() async {
        let snapshot = "snap"
        let playlistA = PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B", snapshotID: snapshot)
        let playlistC = PlaylistBrowsingTestFixtures.playlist(id: "c", name: "C", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB, playlistC])],
            trackResults: [
                "a": [.success([PlaylistBrowsingTestFixtures.track(id: "ta")])],
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])],
                "c": [.success([PlaylistBrowsingTestFixtures.track(id: "tc")])],
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB, playlistC], playlistListCacheAge: 20_000)
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        // Load lands on Home, so select the first playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)

        await viewModel.selectPlaylist(id: "a")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await viewModel.selectNextPlaylist() }
            group.addTask { await viewModel.selectNextPlaylist() }
        }
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["c"], 1)
    }

}
