import AppKit
import Combine
import XCTest
@testable import Spotiglass

/// Taking songs out of the queue and putting them back (#628), on the Apple Music provider with
/// the scripted MusicKit player: the cases from the issue (one song, a selection from the middle,
/// Clear, Undo of each) and what has to stay true around them (the song is gone from what
/// actually plays next, Add to Queue keeps its order, a queue that moved on meanwhile).
@MainActor
final class QueueRemovalTests: XCTestCase {
    private let deviceID = AppleMusicPlaybackProvider.deviceID
    private let songs = (1...8).map { "applemusic:song:\($0)" }

    private struct Harness {
        let player: ScriptedAppleMusicPlayer
        let provider: AppleMusicPlaybackProvider
        let session: PlaybackSessionViewModel
        let queue: QueueViewModel
    }

    private func playing(_ uris: [String]) async throws -> Harness {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = deviceID
        session.setActivePlaybackDeviceID(deviceID)
        let queue = QueueViewModel(provider: provider, playbackSession: session)
        try await provider.play(.items(uris: uris, startURI: nil), deviceID: deviceID)
        player.advance(by: 1)
        await session.syncTransportFromSpotify()
        queue.isPanelVisible = true
        await queue.requestQueueRefresh(trigger: .event, allowsHiddenPanel: false)
        return Harness(player: player, provider: provider, session: session, queue: queue)
    }

    /// The panel's ids of the upcoming rows showing these songs.
    private func ids(_ h: Harness, _ uris: [String]) -> Set<QueueItem.ID> {
        Set(h.queue.upcomingItems.filter { uris.contains($0.uri ?? "") }.map(\.id))
    }

    private func next(_ h: Harness) async throws {
        try await h.provider.skipToNext(deviceID: deviceID)
        h.player.advance(by: 1)
    }

    // MARK: - Remove

    /// A selection from the middle of the queue: the songs leave the panel and the player's
    /// queue, and the next songs that play skip them.
    func testRemovingASelectionFromTheMiddleTakesItOutOfWhatPlaysNext() async throws {
        let h = try await playing(songs)

        let receipt = await h.queue.removeItems(withIDs: ids(h, [songs[3], songs[4]]))

        XCTAssertEqual(receipt?.count, 2)
        XCTAssertEqual(h.player.upcomingURIs, [songs[1], songs[2], songs[5], songs[6], songs[7]])
        XCTAssertEqual(h.queue.upcomingItems.map(\.uri), [songs[1], songs[2], songs[5], songs[6], songs[7]])
        XCTAssertEqual(h.queue.lastRemoval?.count, 2, "the Undo bar offers the removal")

        try await next(h)
        try await next(h)
        try await next(h)
        XCTAssertEqual(h.player.readState().current?.uri, songs[5], "song 4 and 5 never play")
    }

    /// Undo puts the songs back in the same spot.
    func testUndoPutsARemovedSelectionBackWhereItWas() async throws {
        let h = try await playing(songs)
        let receiptResult = await h.queue.removeItems(withIDs: ids(h, [songs[2], songs[5]]))
        let receipt = try XCTUnwrap(receiptResult)

        await h.queue.undoRemoval(receipt)

        XCTAssertEqual(h.player.upcomingURIs, Array(songs.dropFirst()))
        XCTAssertEqual(h.queue.upcomingItems.map(\.uri), Array(songs.dropFirst()))
        XCTAssertNil(h.queue.lastRemoval, "nothing left to undo")
    }

    /// Clear takes out everything after the current song (also what the panel doesn't list), the
    /// current song keeps playing, and Undo brings it all back.
    func testClearRemovesEverythingAfterTheCurrentSongAndUndoBringsItBack() async throws {
        let long = (1...40).map { "applemusic:song:\($0)" }
        let h = try await playing(long)
        XCTAssertEqual(h.queue.upcomingItems.count, h.queue.maxUpcomingItems, "the panel lists 20 of 39")

        let receiptResult = await h.queue.clearUpcoming()
        let receipt = try XCTUnwrap(receiptResult)

        XCTAssertEqual(receipt.count, 39)
        XCTAssertEqual(h.player.upcomingURIs, [])
        XCTAssertEqual(h.queue.upcomingItems, [])
        XCTAssertEqual(h.player.readState().current?.uri, long[0])
        XCTAssertEqual(h.player.readState().status, .playing)

        await h.queue.undoRemoval(receipt)
        XCTAssertEqual(h.player.upcomingURIs, Array(long.dropFirst()))
    }

    /// The panel was read, then a song ended before the listener's Remove reached the player:
    /// the song the listener picked goes, not the one that moved into its place.
    func testARemovalAfterTheQueueMovedOnStillTakesThePickedSong() async throws {
        let h = try await playing(songs)
        let picked = ids(h, [songs[3]])
        try await next(h) // song 2 plays now; the panel hasn't read the queue again

        _ = await h.queue.removeItems(withIDs: picked)

        XCTAssertEqual(h.player.upcomingURIs, [songs[2], songs[4], songs[5], songs[6], songs[7]])
    }

    /// The same song queued twice, [A, B, A, C]: the listener selects the first A, it starts
    /// playing before Remove reaches the player, and the later A stays queued.
    func testARemovedDuplicateThatStartedPlayingKeepsTheLaterCopy() async throws {
        let a = "applemusic:song:a"
        let h = try await playing([songs[0], a, songs[1], a, songs[2]])
        let firstA = try XCTUnwrap(h.queue.upcomingItems.first)
        XCTAssertEqual(firstA.uri, a)
        try await next(h) // the first A plays now; the panel hasn't read the queue again

        _ = await h.queue.removeItems(withIDs: [firstA.id])

        XCTAssertEqual(h.player.readState().current?.uri, a)
        XCTAssertEqual(h.player.upcomingURIs, [songs[1], a, songs[2]])
    }

    /// The same song back to back, [A, A]: the listener selects the first A, it starts playing
    /// before Remove reaches the player, and the second A, which wasn't selected, stays queued.
    func testBackToBackCopiesKeepTheUnselectedOneWhenTheFirstStartedPlaying() async throws {
        let a = "applemusic:song:a"
        let h = try await playing([songs[0], a, a, songs[1]])
        let firstA = try XCTUnwrap(h.queue.upcomingItems.first)
        try await next(h)

        _ = await h.queue.removeItems(withIDs: [firstA.id])

        XCTAssertEqual(h.player.upcomingURIs, [a, songs[1]])
    }

    /// The playing row isn't upcoming, so a selection that includes it removes only the rest.
    func testTheCurrentSongIsNeverRemoved() async throws {
        let h = try await playing(songs)
        var selection = ids(h, [songs[1]])
        selection.insert(try XCTUnwrap(h.queue.nowPlayingItem?.id))

        _ = await h.queue.removeItems(withIDs: selection)

        XCTAssertEqual(h.player.readState().current?.uri, songs[0])
        XCTAssertEqual(h.player.upcomingURIs, Array(songs.dropFirst(2)))
    }

    // MARK: - Add to Queue keeps working around removals

    /// Songs added with Add to Queue play in the order added, before the rest. Taking one of
    /// them out must not make the next add land among the playlist's songs.
    func testAnAddAfterRemovingAnAddedSongStillGoesAfterTheOtherAddedSongs() async throws {
        let h = try await playing(songs)
        await h.queue.addToQueue(uris: ["applemusic:song:a", "applemusic:song:b", "applemusic:song:c"])
        await h.queue.requestQueueRefresh(trigger: .manual, allowsHiddenPanel: true)

        _ = await h.queue.removeItems(withIDs: ids(h, ["applemusic:song:b"]))
        await h.queue.addToQueue(uris: ["applemusic:song:d"])

        XCTAssertEqual(
            Array(h.player.upcomingURIs.prefix(4)),
            ["applemusic:song:a", "applemusic:song:c", "applemusic:song:d", songs[1]]
        )
    }

    /// Undo of an added song puts it back among the added songs, so a later add still goes
    /// after all of them.
    func testUndoOfAnAddedSongKeepsItAmongTheAddedSongs() async throws {
        let h = try await playing(songs)
        await h.queue.addToQueue(uris: ["applemusic:song:a", "applemusic:song:b"])
        await h.queue.requestQueueRefresh(trigger: .manual, allowsHiddenPanel: true)
        let receiptResult = await h.queue.removeItems(withIDs: ids(h, ["applemusic:song:a"]))
        let receipt = try XCTUnwrap(receiptResult)

        await h.queue.undoRemoval(receipt)
        await h.queue.addToQueue(uris: ["applemusic:song:c"])

        XCTAssertEqual(
            Array(h.player.upcomingURIs.prefix(4)),
            ["applemusic:song:a", "applemusic:song:b", "applemusic:song:c", songs[1]]
        )
    }

    // MARK: - ⌘Z

    /// Two removals, then the Undo button of the second: ⌘Z still offers the first one. Before,
    /// the button took every queue removal off the Edit menu, so the older one couldn't be undone.
    func testTheUndoButtonLeavesTheEarlierRemovalOnTheEditMenu() async throws {
        let h = try await playing(songs)
        let manager = UndoManager()
        manager.groupsByEvent = false

        func removal(_ uris: [String]) async -> QueueRemovalReceipt? {
            let ids = ids(h, uris)
            var receipt: QueueRemovalReceipt?
            manager.beginUndoGrouping()
            let run = QueueRemovalUndo.run(on: manager, queue: h.queue) {
                receipt = await h.queue.removeItems(withIDs: ids)
                return receipt
            }
            manager.endUndoGrouping()
            await run.value
            return receipt
        }

        let firstResult = await removal([songs[2]])
        XCTAssertNotNil(firstResult)
        let secondResult = await removal([songs[5]])
        let second = try XCTUnwrap(secondResult)

        QueueRemovalUndo.withdraw(second)
        await h.queue.undoRemoval(second)

        XCTAssertTrue(manager.canUndo, "the first removal is still on the Edit menu")
        XCTAssertEqual(h.player.upcomingURIs, [songs[1], songs[3], songs[4], songs[5], songs[6], songs[7]])
    }

    /// ⌘Z pressed before the player answered the removal waits for it and puts the song back,
    /// instead of using up the Edit menu's undo and doing nothing.
    func testCommandZBeforeThePlayerAnsweredStillPutsTheSongBack() async throws {
        let h = try await playing(songs)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let ids = ids(h, [songs[2]])
        let (gate, open) = AsyncStream.makeStream(of: Void.self)

        let watch = QueueRestoreWatch(full: Array(songs.dropFirst()), removed: songs[2])
        let restored = expectation(description: "the song is back in the queue")
        watch.onRestored = { restored.fulfill() }
        let subscription = h.queue.$upcomingItems.sink { watch.saw($0.map(\.uri)) }

        manager.beginUndoGrouping()
        let run = QueueRemovalUndo.run(on: manager, queue: h.queue) {
            for await _ in gate { break }
            return await h.queue.removeItems(withIDs: ids)
        }
        manager.endUndoGrouping()
        manager.undo()
        open.yield()
        await run.value

        await fulfillment(of: [restored], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(h.player.upcomingURIs, Array(songs.dropFirst()))
    }

    /// A removal that took nothing out leaves no ⌘Z of its own, and keeps the one before it.
    func testARemovalThatTookNothingKeepsTheEarlierUndo() async throws {
        let h = try await playing(songs)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let ids = ids(h, [songs[2]])

        manager.beginUndoGrouping()
        let first = QueueRemovalUndo.run(on: manager, queue: h.queue) { await h.queue.removeItems(withIDs: ids) }
        manager.endUndoGrouping()
        await first.value
        manager.beginUndoGrouping()
        let nothing = QueueRemovalUndo.run(on: manager, queue: h.queue) { nil }
        manager.endUndoGrouping()
        await nothing.value

        XCTAssertTrue(manager.canUndo, "the first removal is still on the Edit menu")
        manager.undo()
        XCTAssertFalse(manager.canUndo, "only the removal that took something out was there")
    }

    // MARK: - Spotify

    /// Spotify's Web API has no endpoint that removes a queued song: the queue offers no Remove
    /// that would do nothing, and a removal asked for anyway changes nothing.
    func testSpotifyOffersNoRemoval() async {
        let provider = SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI())
        let queue = QueueViewModel(provider: provider, playbackSession: PlaybackSessionViewModel(provider: provider))
        queue.upcomingItems = [QueueItem(id: "queue:rest:occurrence:0", name: "Song", subtitle: "Artist", albumArtURL: nil, durationMilliseconds: 1, uri: "spotify:track:1")]

        XCTAssertNil(provider.queueEditing)
        XCTAssertFalse(queue.canEditQueue)
        let receipt = await queue.removeItems(withIDs: ["queue:rest:occurrence:0"])
        XCTAssertNil(receipt)
        XCTAssertEqual(queue.upcomingItems.count, 1)
    }

    // MARK: - Planning a removal

    func testARemovalTakesThePlaceThatStillShowsItsSong() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 1, uri: "b"), QueueRemoval(position: 2, uri: "c")],
            upcomingURIs: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(positions, [1, 2])
    }

    /// The same song queued twice: the copy the listener picked goes, not the first one.
    func testARemovalOfADuplicateTakesThePickedCopy() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 3, uri: "a")],
            upcomingURIs: ["a", "b", "c", "a"]
        )
        XCTAssertEqual(positions, [3])
    }

    /// The same song twice, [A, B, A, C]: the listener picks the first A, and it starts playing
    /// before the removal runs. The later A, which the listener didn't pick, stays.
    func testAPickedSongThatStartedPlayingLeavesTheLaterCopyAlone() {
        let seen = QueueSnapshot(current: "x", upcoming: ["a", "b", "a", "c"])
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 0, uri: "a")],
            upcomingURIs: ["b", "a", "c"],
            currentURI: "a",
            seen: seen
        )
        XCTAssertEqual(positions, [])

        let later = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 2, uri: "a")],
            upcomingURIs: ["b", "a", "c"],
            currentURI: "a",
            seen: seen
        )
        XCTAssertEqual(later, [1], "picking the later A after the first one ended takes that one")
    }

    /// The same song back to back, [A, A]: the first one starts playing before the removal
    /// runs. The second A is a copy the listener didn't pick, and it stays.
    func testBackToBackCopiesKeepTheOneThatWasNotPicked() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 0, uri: "a")],
            upcomingURIs: ["a"],
            currentURI: "a",
            seen: QueueSnapshot(current: "x", upcoming: ["a", "a"])
        )
        XCTAssertEqual(positions, [])
    }

    /// Nothing moved: the picked place is taken as it is, also among copies of one song.
    func testAQueueThatDidNotMoveTakesThePickedPlace() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 1, uri: "a")],
            upcomingURIs: ["a", "a", "a"],
            currentURI: "a",
            seen: QueueSnapshot(current: "a", upcoming: ["a", "a", "a"])
        )
        XCTAssertEqual(positions, [1])
    }

    /// Songs Autoplay added at the end since don't stop the places lining up.
    func testPlacesLineUpWhenSongsWereAddedAtTheEnd() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 2, uri: "c")],
            upcomingURIs: ["b", "c", "d", "x", "y"],
            currentURI: "a",
            seen: QueueSnapshot(current: "z", upcoming: ["a", "b", "c", "d"])
        )
        XCTAssertEqual(positions, [1])
    }

    func testASongThatLeftTheQueueIsLeftOut() {
        let positions = QueueRemovalPlan.positions(
            for: [QueueRemoval(position: 0, uri: "gone"), QueueRemoval(position: 1, uri: "c")],
            upcomingURIs: ["b", "c"]
        )
        XCTAssertEqual(positions, [1])
    }
}

/// Selection in the track stacks that have no table (search results, Home's top tracks).
final class TrackStackSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testClickSelectsOneShiftClickExtendsCommandClickToggles() {
        var selection = TrackStackSelection()
        selection.click("b", in: order, modifiers: [])
        XCTAssertEqual(selection.ids, ["b"])

        selection.click("d", in: order, modifiers: .shift)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])

        selection.click("a", in: order, modifiers: .command)
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d"])
        selection.click("c", in: order, modifiers: .command)
        XCTAssertEqual(selection.ids, ["a", "b", "d"])

        selection.click("e", in: order, modifiers: [])
        XCTAssertEqual(selection.ids, ["e"])
    }

    /// ⌘A selects every row; the arrow keys move from the last row clicked, and with shift extend
    /// the range from the anchor, like a table.
    func testSelectAllAndArrowKeysWorkLikeATable() {
        var selection = TrackStackSelection()
        selection.selectAll(in: order)
        XCTAssertEqual(selection.ids, Set(order))

        selection.click("b", in: order, modifiers: [])
        selection.move(1, in: order, extending: false)
        XCTAssertEqual(selection.ids, ["c"])
        selection.move(1, in: order, extending: true)
        XCTAssertEqual(selection.ids, ["c", "d"])
        selection.move(-2, in: order, extending: true)
        XCTAssertEqual(selection.ids, ["b", "c"], "shift-up past the anchor extends the other way")

        selection.move(-10, in: order, extending: false)
        XCTAssertEqual(selection.ids, ["a"], "the first row is as far as it goes")

        var fresh = TrackStackSelection()
        fresh.move(1, in: order, extending: false)
        XCTAssertEqual(fresh.ids, ["a"], "down with nothing selected starts at the top")
    }

    /// Only the listener's own changes count for focus: new results dropping rows don't, so the
    /// search field keeps focus while the listener types.
    func testOnlyTheListenersChangesAskForFocus() {
        var selection = TrackStackSelection()
        selection.click("b", in: order, modifiers: [])
        selection.click("d", in: order, modifiers: .command)
        let afterClicks = selection.listenerChanges

        selection.keep(only: ["a", "b", "c"])

        XCTAssertEqual(selection.ids, ["b"])
        XCTAssertEqual(selection.listenerChanges, afterClicks)
    }

    /// Right-click on a selected row acts on the whole selection, in list order; on another row
    /// only on that row.
    func testMenuTargetsAreTheSelectionWhenTheClickedRowIsInIt() {
        let tracks = order.map { TrackStackSelectionTests.row($0) }
        var selection = TrackStackSelection()
        selection.click("d", in: order, modifiers: [])
        selection.click("b", in: order, modifiers: .command)

        XCTAssertEqual(selection.menuTargets(for: tracks[3], in: tracks).map(\.id), ["b", "d"])
        XCTAssertEqual(selection.menuTargets(for: tracks[0], in: tracks).map(\.id), ["a"])
    }

    func testNewResultsDropRowsThatAreGone() {
        var selection = TrackStackSelection()
        selection.click("a", in: order, modifiers: [])
        selection.click("c", in: order, modifiers: .shift)
        selection.keep(only: ["b", "x"])
        XCTAssertEqual(selection.ids, ["b"])
        XCTAssertNil(selection.anchor)
    }

    /// The menu says how many tracks it acts on once there is more than one.
    @MainActor
    func testTheMenuNamesTheSelectionCount() {
        XCTAssertNil(TrackOpsMenuItems.selectionLabel(count: 1))
        XCTAssertEqual(TrackOpsMenuItems.selectionLabel(count: 4), SpotiglassL10n.format("playlist.mutation.trackLabel", Int64(4)))
    }

    private static func row(_ id: String) -> TrackRowViewModel {
        TrackRowViewModel(queueItem: QueueItem(id: id, name: id, subtitle: "", albumArtURL: nil, durationMilliseconds: 1, uri: "applemusic:song:\(id)"))
    }
}

/// Sees the panel's queue lose a song and get it back.
@MainActor
private final class QueueRestoreWatch {
    let full: [String?]
    let removed: String
    var onRestored: (() -> Void)?
    private var wasRemoved = false

    init(full: [String], removed: String) {
        self.full = full
        self.removed = removed
    }

    func saw(_ uris: [String?]) {
        if !uris.contains(removed) { wasRemoved = true }
        if wasRemoved, uris == full { onRestored?(); onRestored = nil }
    }
}
