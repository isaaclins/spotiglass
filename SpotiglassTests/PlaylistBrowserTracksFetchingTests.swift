import Combine
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
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])]
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
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1, "Cooldown should skip a second `/items` fetch for the same playlist snapshot.")
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
                    .success([PlaylistBrowsingTestFixtures.track(id: "ta2")])
                ],
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])]
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
                .success([playlistOneV2, playlistTwo])
            ],
            trackResults: [
                "one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")]), .success([PlaylistBrowsingTestFixtures.track(id: "t2")])],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "u1")])]
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
                    .success([PlaylistBrowsingTestFixtures.track(id: "b")])
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
                "b": [.success([PlaylistBrowsingTestFixtures.track(id: "tb")])]
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

        let fetchBStarted = AsyncSignal()
        api.onPlaylistTracksInvocation = { playlistID in
            if playlistID == "b" { fetchBStarted.signal() }
        }
        let firstSwitch = Task { await viewModel.selectPlaylist(id: "b") }
        let didStartFetchB = await fetchBStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartFetchB,
            "the first playlist switch should start fetching playlist B"
        )
        await viewModel.selectPlaylist(id: "a")
        await firstSwitch.value

        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1, "Cancelled in-flight fetch for B should not complete.")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
    }

    func testForbiddenTracksOnFollowedPlaylistShowsLockedState() async {
        // The mock profile id is "u"; the fixture playlist's ownerID is "owner-id",
        // so the playlist is followed (non-owned) and a 403 must produce the locked state.
        let followed = PlaylistBrowsingTestFixtures.playlist(id: "followed", name: "Someone Else's Mix", snapshotID: "snap")
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

        guard case let .error(displayError) = viewModel.detailState else {
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
        let owned = MusicPlaylistSummary(
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

        guard case let .error(displayError) = viewModel.detailState else {
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
                "c": [.success([PlaylistBrowsingTestFixtures.track(id: "tc")])]
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

        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["c"], 1)
    }


    // MARK: - Big playlists (#442)

    private func bigPlaylist(count: Int) -> (MusicPlaylistSummary, [MusicPlaylistTrackItem]) {
        (
            PlaylistBrowsingTestFixtures.playlist(id: "big", name: "My music mix"),
            (0..<count).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") }
        )
    }

    /// Opening "My music mix" (796 songs) showed nothing until the list had laid out every row,
    /// most of a second on its own. The first screen of rows now comes first, then the rest
    /// below it.
    func testALongPlaylistShowsItsFirstScreenOfRowsBeforeTheRest() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        var shown: [[String]] = []
        let observation = viewModel.$detailState.sink { state in
            let rows = PlaylistBrowsingTestFixtures.playlistTracks(state).map(\.id)
            if !rows.isEmpty { shown.append(rows) }
        }

        await viewModel.selectPlaylist(id: "big")
        observation.cancel()

        XCTAssertEqual(shown.first?.count, PlaylistBrowserViewModel.firstScreenRowCount)
        XCTAssertEqual(shown.last, tracks.map(\.id), "every row, in order")
        XCTAssertEqual(shown.count, 2, "every change lays out the whole list again, so the rest goes in one step")
        XCTAssertEqual(shown.first, Array(tracks.map(\.id).prefix(PlaylistBrowserViewModel.firstScreenRowCount)),
                       "the rest is only added below the first screen")
    }

    /// Apple Music reads a playlist's songs all at once, about a second for 800. The songs it
    /// read after launch to count them show at once; the read then replaces them only if the
    /// playlist changed.
    func testAPlaylistShowsTheSongsReadEarlierWhileItIsReadAgain() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let current = tracks + [PlaylistBrowsingTestFixtures.track(id: "added")]
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(current)]])
        api.lastReadTracksByID = ["big": tracks]
        api.playlistTracksDelayOnInvocation = 200_000_000
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        var shownWhileReading: [String] = []
        api.onPlaylistTracksInvocation = { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                shownWhileReading = PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id)
            }
        }

        await viewModel.selectPlaylist(id: "big")

        XCTAssertEqual(shownWhileReading, tracks.map(\.id), "the earlier songs, before the read finished")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), current.map(\.id))
    }

    func testAFreshReadThatMatchesTheShownSongsLeavesTheListAlone() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        api.lastReadTracksByID = ["big": tracks]
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        var changes = 0
        let observation = viewModel.$detailState.dropFirst().sink { state in
            if !PlaylistBrowsingTestFixtures.playlistTracks(state).isEmpty { changes += 1 }
        }

        await viewModel.selectPlaylist(id: "big")
        observation.cancel()

        XCTAssertEqual(changes, 2, "first screen, then all rows; the matching read sets nothing")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["big"], 1)
    }

    func testAShortPlaylistShowsAllItsRowsAtOnce() async {
        let (playlist, tracks) = bigPlaylist(count: 37)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        var shown: [Int] = []
        let observation = viewModel.$detailState.sink { state in
            let count = PlaylistBrowsingTestFixtures.playlistTracks(state).count
            if count > 0 { shown.append(count) }
        }

        await viewModel.selectPlaylist(id: "big")
        observation.cancel()

        XCTAssertEqual(shown, [37])
    }

    /// Opening a playlist from Home sets the sidebar selection, and the sidebar reports that
    /// change back: the playlist was read a second time while the first read still ran.
    func testOpeningAPlaylistFromHomeReadsItOnce() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        api.playlistTracksDelayOnInvocation = 50_000_000
        let reads = ReadCounter()
        api.onPlaylistTracksInvocation = { _ in reads.increment() }
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()

        let opening = Task { await viewModel.selectSidebar(.playlist("big")) }
        // The first read is under way (MusicKit's read doesn't stop when its task is cancelled).
        while reads.count == 0 { await Task.yield() }
        // What the sidebar's selection change does.
        await viewModel.selectSidebar(.playlist("big"))
        await opening.value

        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count, 796)
    }

    /// An album opened from a playlist keeps the sidebar on the playlist. Opening that playlist
    /// from the palette while the album still loads must open the playlist, not be taken for the
    /// sidebar's echo of a load already under way.
    func testOpeningThePlaylistWhileAnAlbumFromItLoadsOpensThePlaylist() async {
        let (playlist, tracks) = bigPlaylist(count: 37)
        let albumTrack = MusicTrack(
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
        let albumReads = ReadCounter()
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["big": [.success(tracks), .success(tracks)]],
            albumTracksHandler: { _, _, _ in
                albumReads.increment()
                try await Task.sleep(for: .milliseconds(200))
                return [albumTrack]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        await viewModel.selectPlaylist(id: "big")

        let album = Task {
            await viewModel.selectAlbum(id: "album-123", displayTitle: "Album Name", displaySubtitle: "Artist Name", artworkURL: nil)
        }
        while albumReads.count == 0 { await Task.yield() }
        await viewModel.selectPlaylist(id: "big")
        await album.value

        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected the playlist, got \(viewModel.detailState)")
        }
        XCTAssertEqual(detail.playlist.id, "big")
        XCTAssertEqual(detail.tracks.map(\.id), tracks.map(\.id))
    }

    /// A count or a name that arrives while the first screen of rows draws rewrites the header.
    /// The rest of the rows must still follow, under the new header.
    func testANewHeaderWhileTheFirstScreenDrawsKeepsTheRestComing() async {
        let (playlist, tracks) = bigPlaylist(count: 100)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        let counted = PlaylistRowViewModel(MusicPlaylistSummary(
            id: "big", name: "My music mix", ownerID: "owner-id", ownerName: "Owner",
            imageURL: nil, trackCount: 100, snapshotID: playlist.snapshotID
        ))
        var rewritten = false
        let observation = viewModel.$detailState.sink { state in
            guard !rewritten, case let .loaded(.playlist(shown)) = state,
                  shown.tracks.count == PlaylistBrowserViewModel.firstScreenRowCount else { return }
            rewritten = true
            // What a count update does to the detail on screen.
            DispatchQueue.main.async {
                viewModel.detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: counted, tracks: shown.tracks)))
            }
        }

        await viewModel.selectPlaylist(id: "big")
        observation.cancel()

        XCTAssertTrue(rewritten)
        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected the playlist, got \(viewModel.detailState)")
        }
        XCTAssertEqual(detail.tracks.map(\.id), tracks.map(\.id), "every row, not the first screen only")
        XCTAssertEqual(detail.playlist, counted, "the newer header stays")
    }

    /// Asking for a playlist's earlier songs can wait. Another playlist opened meanwhile must not
    /// be covered by the first one's loading state once that answer comes back empty.
    func testASlowLookupOfEarlierSongsDoesNotCoverTheNextPlaylist() async {
        let first = PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A")
        let second = PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B")
        let secondTracks = [PlaylistBrowsingTestFixtures.track(id: "b1")]
        let api = MockBrowsingAPI(
            playlistResults: [.success([first, second])],
            trackResults: ["a": [.success([PlaylistBrowsingTestFixtures.track(id: "a1")])], "b": [.success(secondTracks)]]
        )
        api.lastReadDelayNanoseconds = ["a": 200_000_000]
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()

        let opening = Task { await viewModel.selectPlaylist(id: "a") }
        try? await Task.sleep(for: .milliseconds(20))
        await viewModel.selectPlaylist(id: "b")
        await opening.value

        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), ["b1"],
                       "got \(viewModel.detailState)")
    }

    /// Liked Songs read every page (13 for 956 Apple Music songs) before showing a row.
    func testLikedSongsShowTheirFirstPageWhileTheRestIsRead() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        for _ in 0..<50 where PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count < 200 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let whileReading = PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id)
        api.finishReading()
        await opening.value

        XCTAssertEqual(whileReading, first.map(\.id))
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), all.map(\.id))
    }

    func testMemoryCacheKeepsTrackListsBoundedLeastRecentlyUsedFirst() throws {
        let cache = MemoryBrowsingCache(maxTracks: 4)
        let now = Date()
        let two = [PlaylistBrowsingTestFixtures.track(id: "x"), PlaylistBrowsingTestFixtures.track(id: "y")]
        try cache.saveTracks(two, playlistID: "a", snapshotID: "s", cachedAt: now)
        try cache.saveTracks(two, playlistID: "b", snapshotID: "s", cachedAt: now)
        XCTAssertEqual(try cache.loadTracks(playlistID: "a", snapshotID: "s", now: now, maxAge: 60), two)
        try cache.saveTracks(two, playlistID: "c", snapshotID: "s", cachedAt: now)

        XCTAssertNotNil(try cache.loadTracks(playlistID: "a", snapshotID: "s", now: now, maxAge: 60))
        XCTAssertNil(try cache.loadTracks(playlistID: "b", snapshotID: "s", now: now, maxAge: 60))
        XCTAssertNil(try cache.loadTracks(playlistID: "a", snapshotID: "s", now: now.addingTimeInterval(61), maxAge: 60))
        try cache.invalidateTracks(playlistID: "c")
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "c", snapshotID: "s"))
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Liked Songs that hand over their first page, then wait until the test lets the rest finish.
private final class FirstPageSavedTracksAPI: MusicBrowsingProvider, @unchecked Sendable {
    private let firstPage: [MusicPlaylistTrackItem]
    private let all: [MusicPlaylistTrackItem]
    private var restStarted: CheckedContinuation<Void, Never>?
    private var restFinished: CheckedContinuation<Void, Never>?
    private var isRestStarted = false
    private let lock = NSLock()

    init(firstPage: [MusicPlaylistTrackItem], all: [MusicPlaylistTrackItem]) {
        self.firstPage = firstPage
        self.all = all
    }

    func waitUntilRestIsBeingRead() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock { () -> Bool in
                if isRestStarted { return true }
                restStarted = continuation
                return false
            }
            if started { continuation.resume() }
        }
    }

    func finishReading() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { restFinished = nil }
            return restFinished
        }?.resume()
    }

    /// A browser that doesn't ask for the first page reads everything at once.
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isRestStarted = true
            defer { restStarted = nil }
            return restStarted
        }?.resume()
        return MusicSavedTracksResult(tracks: all, totalAvailable: all.count)
    }

    func currentUserSavedTracks(
        limit: Int,
        maxPages: Int?,
        firstPage handOver: @escaping @Sendable (MusicSavedTracksResult) async -> Void
    ) async throws -> MusicSavedTracksResult {
        await handOver(MusicSavedTracksResult(tracks: firstPage, totalAvailable: firstPage.count))
        await withCheckedContinuation { continuation in
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                isRestStarted = true
                restFinished = continuation
                defer { restStarted = nil }
                return restStarted
            }
            waiting?.resume()
        }
        return MusicSavedTracksResult(tracks: all, totalAvailable: all.count)
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { [] }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] { [] }
    func currentUserProfile() async throws -> MusicUserProfile { MusicUserProfile(id: "u", displayName: nil, country: "CH") }
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        MusicArtistDetail(id: id, name: id, imageURL: nil, followersTotal: nil, genres: [], uri: id)
    }
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }
    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        MusicCachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        MusicArtistAlbumsPage(items: [], next: nil)
    }
    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] { [] }
}
