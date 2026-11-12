import XCTest
@testable import Spotiglass

/// Dragging tracks to a new spot in a playlist (#543). Before it, a drag in a playlist only ever
/// pinned the track, so the order could only be changed in the Spotify or Music app.
///
/// The Music app's side replays what its scripting did on macOS 27 with a throwaway playlist:
/// `move <track> to before <track>` and `move <track> to beginning of <playlist>` both put the
/// track at the END of the playlist, `set index` fails (-1731), and `duplicate` adds a second
/// copy. Moving to the end is the one move Music has (the moved entry gets a new entry ID), so
/// `MusicAppMoveToEnd` below does exactly that and nothing else.
@MainActor
final class PlaylistTrackReorderTests: XCTestCase {
    // MARK: - The new order

    func testDroppingRowsGivesTheOrderListShows() {
        // One row down: row 0 dropped before row 3.
        XCTAssertEqual(PlaylistTrackReorder.order(count: 5, moving: [0], toOffset: 3), [1, 2, 0, 3, 4])
        // One row up, and to the very end.
        XCTAssertEqual(PlaylistTrackReorder.order(count: 5, moving: [4], toOffset: 0), [4, 0, 1, 2, 3])
        XCTAssertEqual(PlaylistTrackReorder.order(count: 5, moving: [1], toOffset: 5), [0, 2, 3, 4, 1])
        // Rows selected apart land together, in their order.
        XCTAssertEqual(PlaylistTrackReorder.order(count: 6, moving: [0, 4], toOffset: 3), [1, 2, 0, 4, 3, 5])
        // Dropped onto itself: nothing changes.
        XCTAssertTrue(PlaylistTrackReorder.isUnchanged(PlaylistTrackReorder.order(count: 5, moving: [2], toOffset: 2)))
        XCTAssertTrue(PlaylistTrackReorder.isUnchanged(PlaylistTrackReorder.order(count: 5, moving: [2], toOffset: 3)))
    }

    func testSpotifyRequestsReachEveryDropAndSkipWhatStaysPut() {
        // Every selection of a 7-row playlist dropped at every spot.
        let count = 7
        for mask in 1..<(1 << count) {
            let moving = Set((0..<count).filter { mask & (1 << $0) != 0 })
            for offset in 0...count {
                let order = PlaylistTrackReorder.order(count: count, moving: moving, toOffset: offset)
                var playlist = Array(0..<count)
                let moves = PlaylistTrackReorder.rangeMoves(for: order)
                moves.forEach { PlaylistTrackReorder.apply($0, to: &playlist) }
                XCTAssertEqual(playlist, order, "moving \(moving.sorted()) before \(offset)")
                // A drag of rows that sit together is one request.
                if moving.max()! - moving.min()! + 1 == moving.count {
                    XCTAssertLessThanOrEqual(moves.count, 1)
                }
            }
        }
    }

    func testSpotifyRequestsReachAnyOrder() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let order = Array(0..<40).shuffled(using: &generator)
            var playlist = Array(0..<40)
            PlaylistTrackReorder.rangeMoves(for: order).forEach { PlaylistTrackReorder.apply($0, to: &playlist) }
            XCTAssertEqual(playlist, order)
        }
    }

    func testMusicMovesToTheEndReachEveryDrop() {
        let count = 7
        for mask in 1..<(1 << count) {
            let moving = Set((0..<count).filter { mask & (1 << $0) != 0 })
            for offset in 0...count {
                let order = PlaylistTrackReorder.order(count: count, moving: moving, toOffset: offset)
                var music = MusicAppMoveToEnd(entries: Array(0..<count))
                // The script picks every entry by its ID before it moves any.
                PlaylistTrackReorder.moveToEndSequence(for: order).forEach { music.moveToEnd(entry: $0) }
                XCTAssertEqual(music.entries, order, "moving \(moving.sorted()) before \(offset)")
            }
        }
        // Dragging the last song a little up moves only the songs it passed, not the whole list.
        XCTAssertEqual(PlaylistTrackReorder.moveToEndSequence(for: [0, 1, 2, 5, 3, 4]), [3, 4])
        XCTAssertEqual(PlaylistTrackReorder.moveToEndSequence(for: [1, 2, 3, 0]), [0])
        XCTAssertEqual(PlaylistTrackReorder.moveToEndSequence(for: [0, 1, 2]), [])
    }

    // MARK: - Spotify's reorder endpoint

    func testSpotifySendsTheReorderEndpointWithEachSnapshot() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"snapshot_id": "snapshot-2"}"#, statusCode: 200),
            .json(#"{"snapshot_id": "snapshot-3"}"#, statusCode: 200)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        // Rows 0 and 3 selected and dropped at the end of a 5-row playlist.
        let order = PlaylistTrackReorder.order(count: 5, moving: [0, 3], toOffset: 5)

        let snapshot = try await client.reorderPlaylistTracks(
            playlistID: "playlist-1",
            reorder: MusicPlaylistReorder(order: order, currentTrackIDs: ["a", "b", "c", "d", "e"]),
            snapshotID: "snapshot-1"
        )

        XCTAssertEqual(snapshot, "snapshot-3")
        XCTAssertEqual(httpClient.requests.count, 2)
        let bodies = try httpClient.requests.map { request -> [String: Any] in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/playlists/playlist-1/items")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        XCTAssertNil(bodies[0]["uris"], "a body with uris would replace the playlist")
        XCTAssertEqual(bodies[0]["snapshot_id"] as? String, "snapshot-1")
        XCTAssertEqual(bodies[1]["snapshot_id"] as? String, "snapshot-2")
        var playlist = Array(0..<5)
        for body in bodies {
            let move = MusicPlaylistRangeMove(
                rangeStart: try XCTUnwrap(body["range_start"] as? Int),
                rangeLength: try XCTUnwrap(body["range_length"] as? Int),
                insertBefore: try XCTUnwrap(body["insert_before"] as? Int)
            )
            PlaylistTrackReorder.apply(move, to: &playlist)
        }
        XCTAssertEqual(playlist, [1, 2, 4, 0, 3])
    }

    func testASpotifyRequestThatFailsAfterAnotherWentThroughSaysWhereThePlaylistIs() async throws {
        // The first request is answered; the connection is gone for the second.
        let httpClient = QueueHTTPClient([.json(#"{"snapshot_id": "snapshot-2"}"#, statusCode: 200)])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let order = PlaylistTrackReorder.order(count: 5, moving: [0, 3], toOffset: 5)
        XCTAssertEqual(PlaylistTrackReorder.rangeMoves(for: order).count, 2)

        do {
            _ = try await client.reorderPlaylistTracks(
                playlistID: "playlist-1",
                reorder: MusicPlaylistReorder(order: order, currentTrackIDs: ["a", "b", "c", "d", "e"]),
                snapshotID: "snapshot-1"
            )
            XCTFail("the second request failed")
        } catch let partial as MusicPlaylistReorderPartialFailure {
            var playlist = Array(0..<5)
            PlaylistTrackReorder.apply(PlaylistTrackReorder.rangeMoves(for: order)[0], to: &playlist)
            XCTAssertEqual(partial.orderSoFar, playlist)
            XCTAssertNotEqual(partial.orderSoFar, order)
            XCTAssertEqual(partial.snapshotID, "snapshot-2")
        }
    }

    func testAFirstSpotifyRequestThatFailsChangedNothing() async {
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: QueueHTTPClient([]))
        do {
            _ = try await client.reorderPlaylistTracks(
                playlistID: "playlist-1",
                reorder: MusicPlaylistReorder(order: [1, 0], currentTrackIDs: ["a", "b"]),
                snapshotID: "snapshot-1"
            )
            XCTFail("the request failed")
        } catch {
            XCTAssertFalse(error is MusicPlaylistReorderPartialFailure)
        }
    }

    func testSpotifyOffersReorderingAndNoOtherNewEdits() {
        let client: any MusicBrowsingProvider = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: QueueHTTPClient([])
        )
        // Removing from a playlist, deleting playlists and saving albums stay as they were.
        XCTAssertEqual(client.supportedLibraryEdits, [.reorderPlaylistTracks])
    }

    func testSpotifyPlaylistsSayWhenTheyAreCollaborative() throws {
        let data = Data(#"""
        {"id": "p", "name": "Shared", "owner": {"id": "friend"}, "images": [], "snapshot_id": "s", "collaborative": true}
        """#.utf8)
        let summary = try JSONDecoder().decode(SpotifyPlaylistDTO.self, from: data).domainModel()
        XCTAssertTrue(summary.isCollaborative)
        // A playlist cached before the flag existed still decodes.
        let old = Data(#"{"id":"p","name":"n","ownerID":"o","ownerName":"o","snapshotID":"s"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(MusicPlaylistSummary.self, from: old).isCollaborative)
        let roundTrip = try JSONDecoder().decode(MusicPlaylistSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertTrue(roundTrip.isCollaborative)
    }

    // MARK: - The Music app

    func testMusicChecksThePlaylistThenMovesEntriesByIDToTheEnd() async throws {
        let runner = RecordingScriptRunner()
        let scripting = MusicAppLibraryScripting(runner: runner)

        try await scripting.reorderPlaylist(
            .persistentID("478301A2DB47CCB3"),
            expectedPersistentIDs: ["6276D282E10EAFC9", "5A0A66FCDADF1770", "DF9718D1FB6CFB67"],
            moveToEnd: [2, 0]
        )

        let script = try XCTUnwrap(runner.scripts.first)
        XCTAssertTrue(script.contains(#"set expectedIDs to {"6276D282E10EAFC9", "5A0A66FCDADF1770", "DF9718D1FB6CFB67"}"#))
        XCTAssertTrue(script.contains("if listedIDs is not expectedIDs then error"), "a playlist changed elsewhere moves nothing")
        XCTAssertTrue(script.contains("repeat with position in {3, 1}"))
        XCTAssertTrue(script.contains("move (track id (contents of entryID) of pl) to pl"))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "listedIDs is not expectedIDs")).lowerBound,
            try XCTUnwrap(script.range(of: "move (track id")).lowerBound
        )
    }

    func testAMoveThatAnsweredLateIsFinishedFromWhereItStopped() async throws {
        let runner = RecordingScriptRunner()
        runner.lateProgress = "1|15570, 15572, 15575"
        let scripting = MusicAppLibraryScripting(runner: runner)

        try await scripting.reorderPlaylist(.persistentID("478301A2DB47CCB3"), expectedPersistentIDs: ["A", "B", "C"], moveToEnd: [0, 1, 2])

        let finish = try XCTUnwrap(runner.settled.first)
        XCTAssertFalse(finish.contains("track id 15570"), "moved already")
        // Music gives a moved entry a new ID, so the one that answered late moves only if it
        // still has its old one.
        XCTAssertTrue(finish.contains("if (count of (every track of pl whose id is 15572)) is greater than 0 then move (track id 15572 of pl) to pl"))
        XCTAssertTrue(finish.contains("move (track id 15575 of pl) to pl"))
    }

    func testTheEditorSendsMusicThePersistentIDsTheRowsCarry() async throws {
        let musicApp = MockMusicApp()
        let editor = AppleMusicLibraryEditor(
            lookup: MockLibraryLookup(),
            cloud: MockCloudLibrary(),
            musicApp: musicApp,
            pending: AppleMusicPendingLibraryEdits(),
            songReferences: AppleMusicSongReferenceRegistry()
        )
        // Playlist rows read from the library carry Music's persistent ID as a signed decimal.
        let ids = ["7095089722532212681", "-7021845240094115223"]

        try await editor.reorderPlaylist(playlistID: "5152964197617224883", reorder: MusicPlaylistReorder(order: [1, 0], currentTrackIDs: ids))

        XCTAssertEqual(musicApp.calls, [#"reorder(persistentID("478301A2DB47CCB3"),[6276D282E10EAFC9,9E8D64F51C6C3A69],[0])"#])

        // A song added moments ago that the library doesn't list yet has no persistent ID.
        do {
            try await editor.reorderPlaylist(
                playlistID: "5152964197617224883",
                reorder: MusicPlaylistReorder(order: [1, 0], currentTrackIDs: [ids[0], "1710983273x"])
            )
            XCTFail("expected notInMusicYet")
        } catch {
            XCTAssertEqual(error as? AppleMusicLibraryEditError, .notInMusicYet)
        }
        XCTAssertEqual(musicApp.calls.count, 1, "nothing was sent for it")
    }

    // MARK: - The browser

    private func makeViewModel(_ api: ReorderMockAPI) async -> PlaylistBrowserViewModel {
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
        await viewModel.load()
        await viewModel.selectPlaylist(id: "pl1")
        return viewModel
    }

    private func shownTitles(_ viewModel: PlaylistBrowserViewModel) -> [String] {
        guard case let .playlist(detail)? = viewModel.detailState.currentValue else { return [] }
        return detail.tracks.map(\.title)
    }

    private func shownRows(_ viewModel: PlaylistBrowserViewModel) -> [TrackRowViewModel] {
        guard case let .playlist(detail)? = viewModel.detailState.currentValue else { return [] }
        return detail.tracks
    }

    func testADroppedTrackShowsAtItsNewSpotAtOnceAndTheServiceGetsTheOrder() async throws {
        let api = ReorderMockAPI()
        let gate = LibraryEditsGate()
        api.reorderGate = gate
        let viewModel = await makeViewModel(api)
        XCTAssertTrue(viewModel.canReorderTracks(inPlaylist: "pl1"))
        let before = shownRows(viewModel)
        XCTAssertEqual(before.map(\.title), ["One", "Two", "Three", "Four"])

        // "Four" dragged above "Two".
        let drop = Task { await viewModel.moveTracks(rowIDs: [before[3].id], toOffset: 1, inPlaylist: "pl1") }
        while viewModel.reorderingPlaylistID == nil { await Task.yield() }

        // Shown before the service answered, with the same rows, numbered anew.
        XCTAssertEqual(shownTitles(viewModel), ["One", "Four", "Two", "Three"])
        XCTAssertEqual(shownRows(viewModel).map(\.id), [before[0].id, before[3].id, before[1].id, before[2].id])
        XCTAssertEqual(shownRows(viewModel).map(\.listPosition), [1, 2, 3, 4])
        gate.open()
        await drop.value

        XCTAssertEqual(api.reorders.map(\.order), [[0, 3, 1, 2]])
        XCTAssertEqual(api.reorders.first?.currentTrackIDs, ["t1", "t2", "t3", "t4"])
        XCTAssertEqual(api.reorderSnapshots, ["snap-1"])
        XCTAssertEqual(shownTitles(viewModel), ["One", "Four", "Two", "Three"])
        XCTAssertNil(viewModel.trackMutationToast)

        // The next edit names the playlist by the snapshot the reorder returned.
        let rows = shownRows(viewModel)
        await viewModel.moveTracks(rowIDs: [rows[0].id], toOffset: 4, inPlaylist: "pl1")
        XCTAssertEqual(api.reorderSnapshots, ["snap-1", "snap-2"])
    }

    func testSelectedTracksMoveTogether() async {
        let api = ReorderMockAPI()
        let viewModel = await makeViewModel(api)
        let rows = shownRows(viewModel)

        await viewModel.moveTracks(rowIDs: [rows[0].id, rows[2].id], toOffset: 4, inPlaylist: "pl1")

        XCTAssertEqual(shownTitles(viewModel), ["Two", "Four", "One", "Three"])
        XCTAssertEqual(api.reorders.map(\.order), [[1, 3, 0, 2]])
    }

    func testAFailedSavePutsTheTracksBackWithAOneLineMessage() async {
        let api = ReorderMockAPI()
        api.reorderError = AppleMusicLibraryEditError.musicControlDenied
        let viewModel = await makeViewModel(api)
        let rows = shownRows(viewModel)

        await viewModel.moveTracks(rowIDs: [rows[3].id], toOffset: 0, inPlaylist: "pl1")

        XCTAssertEqual(shownTitles(viewModel), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(shownRows(viewModel), rows)
        XCTAssertEqual(
            viewModel.trackMutationToast,
            SpotiglassL10n.format("playlist.mutation.reorderFailed", AppleMusicLibraryEditError.musicControlDenied.localizedDescription)
        )
        XCTAssertNil(viewModel.reorderingPlaylistID)
    }

    func testAFailedMusicSaveReadsThePlaylistAgain() async {
        let api = ReorderMockAPI()
        api.reorderError = AppleMusicLibraryEditError.notInMusicYet
        api.namesAfterFailure = ["Two", "One", "Three", "Four"]
        let viewModel = await makeViewModel(api)
        let rows = shownRows(viewModel)

        await viewModel.moveTracks(rowIDs: [rows[3].id], toOffset: 0, inPlaylist: "pl1")

        // The list shows the order Music has, not the one this screen had before the drag.
        XCTAssertEqual(shownTitles(viewModel), ["Two", "One", "Three", "Four"])
        XCTAssertNotNil(viewModel.trackMutationToast)
    }

    func testASaveSpotifyTookPartOfShowsThePlaylistAsItIsNow() async {
        let api = ReorderMockAPI()
        // Of [One, Four, Two, Three] only the move of Four went through.
        api.reorderError = MusicPlaylistReorderPartialFailure(orderSoFar: [0, 3, 1, 2], snapshotID: "snap-half", underlying: URLError(.notConnectedToInternet))
        let viewModel = await makeViewModel(api)
        let rows = shownRows(viewModel)

        await viewModel.moveTracks(rowIDs: [rows[3].id, rows[0].id], toOffset: 4, inPlaylist: "pl1")

        XCTAssertEqual(shownTitles(viewModel), ["One", "Four", "Two", "Three"])
        XCTAssertEqual(shownRows(viewModel).map(\.listPosition), [1, 2, 3, 4])
        XCTAssertNotNil(viewModel.trackMutationToast)
        // The next drop counts from that order, under the snapshot it has.
        api.reorderError = nil
        await viewModel.moveTracks(rowIDs: [shownRows(viewModel)[0].id], toOffset: 4, inPlaylist: "pl1")
        XCTAssertEqual(api.reorderSnapshots, ["snap-half"])
        XCTAssertEqual(api.reorders.last?.currentTrackIDs, ["t1", "t4", "t2", "t3"])
    }

    func testADropNamesTheSnapshotOfTheRowsOnScreen() async {
        let api = ReorderMockAPI()
        let viewModel = await makeViewModel(api)
        // A library refresh learned a newer snapshot; the rows on screen are still the ones read
        // at snap-1, and their positions only hold there.
        let summary = viewModel.playlistsByID["pl1"]!
        viewModel.playlistsByID["pl1"] = MusicPlaylistSummary(
            id: summary.id, name: summary.name, ownerID: summary.ownerID, ownerName: summary.ownerName,
            imageURL: nil, trackCount: 5, snapshotID: "snap-newer"
        )

        await viewModel.moveTracks(rowIDs: [shownRows(viewModel)[3].id], toOffset: 0, inPlaylist: "pl1")

        XCTAssertEqual(api.reorderSnapshots, ["snap-1"])
    }

    func testAReadThatBeganBeforeTheSaveDoesNotPutTheOldOrderBack() async {
        let api = ReorderMockAPI()
        let viewModel = await makeViewModel(api)
        // The playlist is opened again: its last rows show at once while a read runs.
        api.lastRead = try? await api.playlistTracks(playlistID: "pl1", limit: 50, maxPages: 1)
        let gate = LibraryEditsGate()
        api.readGate = gate
        let reread = Task { await viewModel.refreshCurrentPlaylistMutationDetail(for: ["pl1"]) }
        while api.readGate != nil { await Task.yield() }

        await viewModel.moveTracks(rowIDs: [shownRows(viewModel)[3].id], toOffset: 0, inPlaylist: "pl1")
        XCTAssertEqual(api.reorders.count, 1)
        gate.open()
        await reread.value

        XCTAssertEqual(shownTitles(viewModel), ["Four", "One", "Two", "Three"])
        if case .refreshing = viewModel.detailState { XCTFail("the read that was left out still shows as running") }
    }

    func testADropWhileTheLastOrderIsSavingDoesNothing() async {
        let api = ReorderMockAPI()
        let gate = LibraryEditsGate()
        api.reorderGate = gate
        let viewModel = await makeViewModel(api)
        let rows = shownRows(viewModel)
        let first = Task { await viewModel.moveTracks(rowIDs: [rows[3].id], toOffset: 0, inPlaylist: "pl1") }
        while viewModel.reorderingPlaylistID == nil { await Task.yield() }

        await viewModel.moveTracks(rowIDs: [rows[1].id], toOffset: 4, inPlaylist: "pl1")
        gate.open()
        await first.value

        XCTAssertEqual(api.reorders.count, 1)
        XCTAssertEqual(shownTitles(viewModel), ["Four", "One", "Two", "Three"])
    }

    func testOnlyPlaylistsTheUserMayEditOfferReordering() async {
        let api = ReorderMockAPI()
        api.playlists += [
            MusicPlaylistSummary(id: "theirs", name: "Theirs", ownerID: "friend", ownerName: "Friend", imageURL: nil, trackCount: 4, snapshotID: "s"),
            MusicPlaylistSummary(
                id: "shared", name: "Shared", ownerID: "friend", ownerName: "Friend", imageURL: nil, trackCount: 4, snapshotID: "s",
                isCollaborative: true
            )
        ]
        let viewModel = await makeViewModel(api)

        XCTAssertTrue(viewModel.canReorderTracks(inPlaylist: "pl1"))
        XCTAssertTrue(viewModel.canReorderTracks(inPlaylist: "shared"))
        XCTAssertFalse(viewModel.canReorderTracks(inPlaylist: "theirs"))
        XCTAssertFalse(viewModel.canReorderTracks(inPlaylist: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID))
        XCTAssertFalse(viewModel.canReorderTracks(inPlaylist: nil))

        let withoutReorder = ReorderMockAPI()
        withoutReorder.edits = []
        let other = await makeViewModel(withoutReorder)
        XCTAssertFalse(other.canReorderTracks(inPlaylist: "pl1"))
        await other.moveTracks(rowIDs: [shownRows(other)[0].id], toOffset: 4, inPlaylist: "pl1")
        XCTAssertEqual(withoutReorder.reorders.count, 0)
        XCTAssertEqual(shownTitles(other), ["One", "Two", "Three", "Four"])
    }
}

/// Music's scripting as measured: moving an entry of a playlist puts it at the end.
private struct MusicAppMoveToEnd {
    var entries: [Int]

    mutating func moveToEnd(entry: Int) {
        guard let index = entries.firstIndex(of: entry) else { return }
        entries.append(entries.remove(at: index))
    }
}

private final class RecordingScriptRunner: MusicAppScriptRunning, @unchecked Sendable {
    var scripts: [String] = []
    var settled: [String] = []
    /// When set, the first script's change answers late with this progress.
    var lateProgress: String?

    func run(_ source: String) async throws -> String? {
        scripts.append(source)
        if let lateProgress {
            self.lateProgress = nil
            throw MusicAppLateChange(progress: lateProgress)
        }
        return nil
    }

    func settle(_ source: String) async throws -> String? {
        settled.append(source)
        return nil
    }
}

/// A playlist of four tracks owned by the signed-in user, and a provider that records reorders.
private final class ReorderMockAPI: MusicBrowsingProvider, @unchecked Sendable {
    var edits: MusicLibraryEdits = [.reorderPlaylistTracks]
    var playlists = [
        MusicPlaylistSummary(id: "pl1", name: "Spotiglass test", ownerID: "me", ownerName: "Me", imageURL: nil, trackCount: 4, snapshotID: "snap-1")
    ]
    var reorderGate: LibraryEditsGate?
    var reorderError: Error?
    /// The playlist's order on the service from the first failed reorder on, as when it was
    /// changed elsewhere or Music stopped partway.
    var namesAfterFailure: [String]?
    private var names = ["One", "Two", "Three", "Four"]
    /// When set, the next read of the tracks waits for it, holding the order it had when it began.
    var readGate: LibraryEditsGate?
    /// The tracks read last, for a reopened playlist to show while the read runs.
    var lastRead: [MusicPlaylistTrackItem]?
    private(set) var reorders: [MusicPlaylistReorder] = []
    private(set) var reorderSnapshots: [String?] = []

    var supportedLibraryEdits: MusicLibraryEdits { edits }

    func reorderPlaylistTracks(playlistID: String, reorder: MusicPlaylistReorder, snapshotID: String?) async throws -> String? {
        await reorderGate?.wait()
        if let reorderError {
            if let namesAfterFailure { names = namesAfterFailure }
            throw reorderError
        }
        reorders.append(reorder)
        reorderSnapshots.append(snapshotID)
        return "snap-\(reorders.count + 1)"
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { playlists }
    func lastReadPlaylistTracks(playlistID: String) async -> [MusicPlaylistTrackItem]? { lastRead }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        let names = names
        if let gate = readGate {
            readGate = nil
            await gate.wait()
        }
        return names.enumerated().map { index, name in
            let track = MusicTrack(
                id: "t\(index + 1)", name: name, artists: ["Artist"], albumArtworkURL: nil, durationMilliseconds: 1000,
                isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t\(index + 1)"
            )
            return MusicPlaylistTrackItem(id: "t\(index + 1):\(index)", content: .track(track))
        }
    }
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
    func currentUserProfile() async throws -> MusicUserProfile {
        MusicUserProfile(id: "me", displayName: nil, country: nil)
    }
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        throw AppleMusicBrowsingError.notFound
    }
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        throw AppleMusicBrowsingError.notFound
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
