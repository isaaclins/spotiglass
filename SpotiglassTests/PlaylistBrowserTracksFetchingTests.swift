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

        // From here reads are held until the test lets them go, or until their task is cancelled.
        let readsHeld = AsyncSignal()
        api.playlistTracksHold = readsHeld
        let fetchBStarted = AsyncSignal()
        api.onPlaylistTracksInvocation = { playlistID in
            if playlistID == "b" { fetchBStarted.signal() }
            // Reading A again would be a bug the assertions catch; don't let it hang the test.
            if playlistID == "a" { readsHeld.signal() }
        }
        let firstSwitch = Task { await viewModel.selectPlaylist(id: "b") }
        guard await waitFor(fetchBStarted, "the first playlist switch fetching playlist B") else { return readsHeld.signal() }
        guard await finishes("switching back to A waited for B's held read", elseRelease: readsHeld.signal, {
            await viewModel.selectPlaylist(id: "a")
        }) else { return }
        // B's read is let go only now: if the switch back to A didn't cancel it, it finishes.
        readsHeld.signal()
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
        let clock = ManualPlaybackClock()
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30,
            adjacentPlaylistClock: clock
        )

        await viewModel.load()
        // Load lands on Home, so select the first playlist explicitly to fetch its items.
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)

        await viewModel.selectPlaylist(id: "a")
        // Both presses land inside the debounce however busy the machine is: its clock is stepped
        // only once both are in (#510).
        let first = Task { await viewModel.selectNextPlaylist() }
        let second = Task { await viewModel.selectNextPlaylist() }
        while viewModel.pendingAdjacentPlaylistOffset < 2 { await Task.yield() }
        clock.advance(by: PlaylistBrowserViewModel.adjacentPlaylistDebounce)
        await first.value
        await second.value

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
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
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
        let readHeld = AsyncSignal()
        let readStarted = AsyncSignal()
        api.playlistTracksHold = readHeld
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()
        api.onPlaylistTracksInvocation = { _ in readStarted.signal() }

        let opening = Task { await viewModel.selectPlaylist(id: "big") }
        guard await waitFor(readStarted, "the read of the playlist") else { return readHeld.signal() }
        // The read is held: whatever shows now came from the earlier read.
        await waitUntil("the songs read earlier on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count == tracks.count
        }
        let shownWhileReading = PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id)
        readHeld.signal()
        await opening.value

        XCTAssertEqual(shownWhileReading, tracks.map(\.id), "the earlier songs, before the read finished")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), current.map(\.id))
    }

    func testAFreshReadThatMatchesTheShownSongsLeavesTheListAlone() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        api.lastReadTracksByID = ["big": tracks]
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
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
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
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
        let firstReadStarted = AsyncSignal()
        let readsHeld = AsyncSignal()
        api.playlistTracksHold = readsHeld
        let reads = ReadCounter()
        api.onPlaylistTracksInvocation = { _ in
            reads.increment()
            // A second read is the bug under test: let it run so the count shows it.
            if reads.count == 1 { firstReadStarted.signal() } else { readsHeld.signal() }
        }
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()

        let opening = Task { await viewModel.selectSidebar(.playlist("big")) }
        // The first read is under way and held until the sidebar has reported back.
        guard await waitFor(firstReadStarted, "the first read") else { return readsHeld.signal() }
        // What the sidebar's selection change does.
        guard await finishes("the sidebar's report waited for the held first read", elseRelease: readsHeld.signal, {
            await viewModel.selectSidebar(.playlist("big"))
        }) else { return }
        readsHeld.signal()
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
        let albumHeld = AsyncSignal()
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["big": [.success(tracks), .success(tracks)]],
            albumTracksHandler: { _, _, _ in
                albumReads.increment()
                // Still loading until the playlist was opened over it.
                await albumHeld.wait()
                try Task.checkCancellation()
                return [albumTrack]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()
        await viewModel.selectPlaylist(id: "big")

        let album = Task {
            await viewModel.selectAlbum(id: "album-123", displayTitle: "Album Name", displaySubtitle: "Artist Name", artworkURL: nil)
        }
        await pollUntil { albumReads.count > 0 }
        guard await finishes("opening the playlist waited for the held album read", elseRelease: albumHeld.signal, {
            await viewModel.selectPlaylist(id: "big")
        }) else { return }
        albumHeld.signal()
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
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
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
        let lookup = MockBrowsingAPI.LastReadHold()
        api.lastReadHolds = ["a": lookup]
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()

        let opening = Task { await viewModel.selectPlaylist(id: "a") }
        // A's lookup is in flight when B opens, and answers only after B has.
        await lookup.entered.wait()
        await viewModel.selectPlaylist(id: "b")
        lookup.release.signal()
        await opening.value

        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), ["b1"],
                       "got \(viewModel.detailState)")
    }

    /// Liked Songs read every page (13 for 956 Apple Music songs) before showing a row.
    func testLikedSongsShowTheirFirstPageWhileTheRestIsRead() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        let whileReading = PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id)
        api.finishReading()
        await opening.value

        XCTAssertEqual(whileReading, first.map(\.id))
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.id), all.map(\.id))
    }

    /// Play, Shuffle or a double-click while Liked Songs show their first page queued only that
    /// page, and nothing added the rest. Playing now waits for the full read.
    func testPlayingLikedSongsWhileTheRestIsReadQueuesEverySong() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        XCTAssertEqual(firstPage.tracks.count, 200)
        let playing = Task { await viewModel.detailForPlayback(firstPage) }
        api.finishReading()
        let played = await playing.value
        await opening.value

        XCTAssertEqual(played?.tracks.map(\.id), all.map(\.id), "every song, not the first page")
        if let played {
            XCTAssertEqual(DetailHeaderPlayback.target(for: played),
                           .tracks(uris: played.tracks.compactMap(\.playableURI), playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID))
        }
    }

    /// The read can be done while its rows wait for the owner lookup before going on screen.
    /// Playing from the first page then must still get every song.
    func testPlayingLikedSongsAfterTheReadButBeforeTheRowsShowQueuesEverySong() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let ownerHeld = AsyncSignal()
        api.profileHoldAfterRead = ownerHeld
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        api.finishReading()
        guard await waitFor(api.profileAskedAfterRead, "the owner lookup after the read") else { return ownerHeld.signal() }
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count, 200, "the rows wait for the owner")

        let started = viewModel.playbackRequestGeneration
        let playing = Task { await viewModel.detailForPlayback(firstPage) }
        await waitForPlay(after: started, on: viewModel)
        ownerHeld.signal()
        let played = await playing.value
        await opening.value

        XCTAssertEqual(played?.tracks.map(\.id), all.map(\.id))
    }

    /// A long list shows its first screen of rows for a moment before the rest. Playing from
    /// those rows must queue the whole list, Spotify's too.
    func testPlayingFromALongListsFirstScreenQueuesTheWholeList() async {
        let (playlist, tracks) = bigPlaylist(count: 796)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()
        var firstScreen: PlaylistDetailViewModel?
        let observation = viewModel.$detailState.sink { state in
            if firstScreen == nil, case let .playlist(shown)? = state.currentValue,
               shown.tracks.count == PlaylistBrowserViewModel.firstScreenRowCount {
                firstScreen = shown
            }
        }
        await viewModel.selectPlaylist(id: "big")
        observation.cancel()

        // What a row or the header captured while the first screen was drawn.
        guard let firstScreen else { return XCTFail("Expected a first screen of rows") }
        let played = await viewModel.detailForPlayback(firstScreen)

        XCTAssertEqual(played?.tracks.map(\.id), tracks.map(\.id))
    }

    /// Rows that aren't the start of the list on screen (a list changed since) play as shown.
    func testPlayingRowsThatAreNotTheStartOfTheListPlaysThemAsShown() async {
        let (playlist, tracks) = bigPlaylist(count: 100)
        let api = MockBrowsingAPI(playlistResults: [.success([playlist])], trackResults: ["big": [.success(tracks)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()
        await viewModel.selectPlaylist(id: "big")
        guard case let .playlist(shown)? = viewModel.detailState.currentValue else { return XCTFail() }
        let other = PlaylistDetailViewModel(playlist: shown.playlist, tracks: Array(shown.tracks.dropFirst()))

        let played = await viewModel.detailForPlayback(other)

        XCTAssertEqual(played, other)
    }

    /// A play from the first page waits for the rest. Opening another surface or asking for
    /// another play meanwhile wins: the waiting play mustn't replace it when the read finishes.
    func testAPlayWaitingForLikedSongsGivesWayToANewerChoice() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        let started = viewModel.playbackRequestGeneration
        let earlier = Task { await viewModel.detailForPlayback(firstPage) }
        await waitForPlay(after: started, on: viewModel)
        let newer = Task { await viewModel.detailForPlayback(firstPage) }
        await waitForPlay(after: started + 1, on: viewModel)
        api.finishReading()

        let earlierResult = await earlier.value
        let newerResult = await newer.value
        await opening.value
        XCTAssertNil(earlierResult, "a newer play came after it")
        XCTAssertEqual(newerResult?.tracks.count, 956)
    }

    func testAPlayWaitingForLikedSongsGivesWayToAnotherSurface() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        let started = viewModel.playbackRequestGeneration
        let waiting = Task { await viewModel.detailForPlayback(firstPage) }
        await waitForPlay(after: started, on: viewModel)
        // Leaving Liked Songs before the read finishes.
        guard await finishes("leaving Liked Songs waited for the held read", elseRelease: api.finishReading, {
            await viewModel.selectSidebar(nil)
        }) else { return }
        api.finishReading()

        let result = await waiting.value
        await opening.value
        XCTAssertNil(result)
    }

    /// Any playback command from elsewhere while a play waits (a pinned track, Home, the player
    /// bar, a media key) wins over it.
    func testAPlayWaitingForLikedSongsGivesWayToAnyOtherPlaybackCommand() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        let commands = ReadCounter()
        let started = viewModel.playbackRequestGeneration
        let waiting = Task { await viewModel.detailForPlayback(firstPage, playbackCommands: { UInt64(commands.count) }) }
        await waitForPlay(after: started, on: viewModel)
        commands.increment() // A pinned track starts playing meanwhile.
        api.finishReading()

        let result = await waiting.value
        await opening.value
        XCTAssertNil(result)
    }

    /// A play that waited for a read that then failed must still give way to what came after.
    func testAPlayWaitingForAFailedLikedSongsReadGivesWayToAnotherSurface() async {
        let first = (0..<200).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let all = (0..<956).map { PlaylistBrowsingTestFixtures.track(id: "l\($0)") }
        let api = FirstPageSavedTracksAPI(firstPage: first, all: all)
        api.restFails = true
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())

        let opening = Task { await viewModel.selectSidebar(.likedSongs) }
        await api.waitUntilRestIsBeingRead()
        await waitUntil("the first page on screen", changes: viewModel.$detailState) {
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count >= 200
        }
        guard case let .playlist(firstPage)? = viewModel.detailState.currentValue else {
            return XCTFail("Expected the first page, got \(viewModel.detailState)")
        }
        let started = viewModel.playbackRequestGeneration
        let waiting = Task { await viewModel.detailForPlayback(firstPage) }
        await waitForPlay(after: started, on: viewModel)
        guard await finishes("leaving Liked Songs waited for the held read", elseRelease: api.finishReading, {
            await viewModel.selectSidebar(nil)
        }) else { return }
        api.finishReading()

        let result = await waiting.value
        await opening.value
        XCTAssertNil(result)
    }

    /// The count a waiting play compares: every route a user starts or changes playback by
    /// (rows, Home, pinned items, the queue, the player bar, media keys) ends in one of these.
    func testThePlayerCountsEveryPlaybackCommand() async {
        let player = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let before = player.playbackCommandCount

        await player.play(uri: "spotify:track:a")
        await player.play(contextURI: "spotify:playlist:p")
        await player.playFromPlaylist(clickedURI: "spotify:track:a", playableURIs: ["spotify:track:a"])
        await player.requestTogglePlayPause()?.value
        await player.next()
        await player.previous()

        XCTAssertEqual(player.playbackCommandCount, before + 6)
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

    /// Waits until a play asked for after `generation` has started, i.e. has read its request
    /// number and its baseline of playback commands, however late a busy machine runs its task.
    /// A play that never starts fails the test; the caller then lets its held read go.
    private func waitForPlay(
        after generation: Int,
        on viewModel: PlaylistBrowserViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await pollUntil({ viewModel.playbackRequestGeneration > generation }, file: file, line: line)
    }
}

extension PlaylistBrowserTracksFetchingTests {
    /// Waits for something the view model does on a later turn of the main actor. It yields
    /// instead of sleeping, so it ends the moment the condition holds on any machine; the
    /// deadline only stops a broken run.
    func pollUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(mustHappenTimeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the view model never got there", file: file, line: line)
            }
            await Task.yield()
        }
    }

    /// Waits for `signal`, or fails once `limit` passes. The limit only bounds how long a broken
    /// build takes to fail; on a working one the signal ends the wait.
    func waitFor(
        _ signal: AsyncSignal,
        _ what: String,
        limit: Duration = .seconds(mustHappenTimeout),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let fired = await signal.wait(timeout: limit)
        if !fired { XCTFail("\(what) never happened", file: file, line: line) }
        return fired
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
    private var isReadFinished = false
    /// The rest of the read fails instead of answering.
    var restFails = false
    /// Holds the owner lookup that comes after the read until the signal fires.
    var profileHoldAfterRead: AsyncSignal?
    /// Fires when the owner is asked for after the read.
    let profileAskedAfterRead = AsyncSignal()
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
            isReadFinished = true
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
        if lock.withLock({ restFails }) { throw URLError(.notConnectedToInternet) }
        return MusicSavedTracksResult(tracks: all, totalAvailable: all.count)
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { [] }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] { [] }
    func currentUserProfile() async throws -> MusicUserProfile {
        if let hold = lock.withLock({ isReadFinished ? profileHoldAfterRead : nil }) {
            profileAskedAfterRead.signal()
            await Task.detached { await hold.wait() }.value
        }
        return MusicUserProfile(id: "u", displayName: nil, country: "CH")
    }
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
