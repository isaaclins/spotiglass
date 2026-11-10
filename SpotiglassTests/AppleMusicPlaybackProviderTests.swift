import MusicKit
import XCTest
@testable import Spotiglass

/// Apple Music playback: the provider's mapping onto MusicKit's `ApplicationMusicPlayer`
/// (through a scripted player), the session against the lag measured on a real Mac, the
/// neutral playback errors and the service-neutral lyrics key.
@MainActor
final class AppleMusicPlaybackProviderTests: XCTestCase {
    // MARK: - Provider

    func testProviderIsOneLocalPlayerWithoutPushedStateTransferOrVolume() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        var events: [MusicPlaybackEvent] = []
        provider.eventHandler = { events.append($0.event) }

        XCTAssertEqual(provider.capabilities, [])
        XCTAssertNil(provider.deviceTransfer)
        try await provider.connectPlayer(generation: .initial)
        try await provider.connectPlayer(generation: .initial.advanced())
        XCTAssertEqual(events, [
            .ready(deviceID: AppleMusicPlaybackProvider.deviceID),
            .ready(deviceID: AppleMusicPlaybackProvider.deviceID),
        ])

        let session = PlaybackSessionViewModel(provider: provider)
        XCTAssertFalse(session.supportsPlayerVolume)
        XCTAssertTrue(session.isPlayerStateRead)
        XCTAssertFalse(session.supportsDeviceTransfer)
    }

    /// A press that knows the state it wants pauses or plays, whatever the player shows (#437).
    func testSetInAppPlayerPlayingPausesAndResumes() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        try await provider.setInAppPlayerPlaying(false, commandID: nil)
        try await provider.setInAppPlayerPlaying(true, commandID: nil)
        XCTAssertEqual(player.commands.filter { $0 == "pause" || $0 == "resume" }, ["pause", "resume"])
    }

    func testConnectWithoutAppleMusicAccessFailsWithAnAppleMusicError() async {
        let player = ScriptedAppleMusicPlayer()
        player.authorized = false
        let provider = AppleMusicPlaybackProvider(player: player)
        do {
            try await provider.connectPlayer(generation: .initial)
            XCTFail("Expected a permission error")
        } catch {
            XCTAssertEqual(MusicPlaybackError.from(error)?.service, .appleMusic)
            XCTAssertEqual(MusicPlaybackError.from(error)?.reason, .missingPermission)
        }
    }

    func testPlayRequestsBecomeMusicKitQueues() throws {
        XCTAssertEqual(
            try AppleMusicPlaybackProvider.queueRequest(for: .item(uri: "applemusic:song:1")),
            .items(uris: ["applemusic:song:1"], startURI: "applemusic:song:1")
        )
        XCTAssertEqual(
            try AppleMusicPlaybackProvider.queueRequest(
                for: .items(uris: ["applemusic:song:1", "spotify:track:x", "applemusic:song:-2"], startURI: "applemusic:song:-2")
            ),
            .items(uris: ["applemusic:song:1", "applemusic:song:-2"], startURI: "applemusic:song:-2")
        )
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:album:1440857781")), .album(id: "1440857781"))
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:playlist:p.abc")), .playlist(id: "p.abc"))
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:artist:42")), .artist(id: "42"))
        XCTAssertThrowsError(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "spotify:album:abc"))) { error in
            XCTAssertEqual(MusicPlaybackError.from(error)?.service, .appleMusic)
            XCTAssertEqual(MusicPlaybackError.from(error)?.reason, .notFound)
        }
    }

    func testReadsMapThePlayerStateAndTheQueue() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let noState = try await provider.fetchPlaybackState()
        XCTAssertNil(noState, "an empty queue reads as nothing active")

        try await provider.play(.items(uris: Self.uris, startURI: Self.uris[1]), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.advance(by: 1)
        try await provider.setShuffle(enabled: true, deviceID: "x")
        try await provider.setRepeat(mode: .context, deviceID: "x")
        try await provider.seek(to: 61_500, deviceID: "x")

        let read = try await provider.fetchPlaybackState()
        let snapshot = try XCTUnwrap(read)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.playbackNowPlaying?.uri, Self.uris[1])
        XCTAssertEqual(snapshot.progressMilliseconds, 61_500)
        XCTAssertEqual(snapshot.transport, MusicPlaybackTransport(shuffle: true, repeatMode: .context))
        XCTAssertNil(snapshot.activeDevice)

        let queue = try await provider.fetchQueue()
        XCTAssertEqual(queue.queue.compactMap(Self.uri), Array(Self.uris[2...]))
    }

    func testAddToQueuePlaysInTheOrderAdded() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        let queue = QueueViewModel(provider: provider, playbackSession: session)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x")

        await queue.addToQueue(uris: ["applemusic:song:a", "applemusic:song:b"])

        let upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(Array(upcoming.prefix(3)), ["applemusic:song:a", "applemusic:song:b", Self.uris[1]])
    }

    // MARK: - Queue panel (#413)

    /// The case seen in the app: Liked Songs (2,543 songs) started playing, the queue panel
    /// was opened while Spotiglass was not the active app, and it said "0 tracks up next"
    /// until the app was activated. Opening the panel reads the queue in the background too.
    func testOpeningThePanelInTheBackgroundShowsALongListAtOnce() async throws {
        let likedSongs = (1...2_543).map { "applemusic:song:\($0)" }
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        try await provider.play(.items(uris: likedSongs, startURI: nil), deviceID: "x")
        player.advance(by: 1)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.currentNowPlaying?.uri, likedSongs[0])

        let queue = QueueViewModel(provider: provider, playbackSession: session)
        queue.setAppActive(false)
        await Self.openPanel(queue)

        XCTAssertEqual(queue.upcomingItems.map(\.uri), Array(likedSongs[1...20]))
        XCTAssertNil(queue.pollTask, "the timed poll still waits for the app to be active")
    }

    /// Opened while the play is still looking up its songs, the panel used to read the queue
    /// the player had before (none here) and keep it until the next poll. The read now waits
    /// for that play and shows the list it started.
    func testOpeningThePanelWhileALongListStartsShowsThatList() async throws {
        let likedSongs = (1...2_543).map { "applemusic:song:\($0)" }
        let player = ScriptedAppleMusicPlayer()
        player.holdLookups = true
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        session.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        let queue = QueueViewModel(provider: provider, playbackSession: session)

        let play = Task { try await provider.play(.items(uris: likedSongs, startURI: nil), deviceID: "x") }
        while player.waitingLookups.isEmpty { await Task.yield() }
        let open = Task { await Self.openPanel(queue) }
        for _ in 0..<20 { await Task.yield() }
        player.releaseLookups()
        try await play.value
        await open.value

        XCTAssertEqual(queue.upcomingItems.map(\.uri), Array(likedSongs[1...20]))
    }

    /// A slow play is replaced by a quick one while the panel is reading the queue. The read
    /// shows the newer play's list as soon as that play is in, without waiting for the
    /// replaced play's lookup to end.
    func testAReadDuringAReplacedPlayShowsTheNewerPlay() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        player.holdLookups = true
        let slow = Task { try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x") }
        await Self.settle()
        XCTAssertEqual(player.waitingLookups.count, 1)

        var upcoming: [String]?
        let read = Task { upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri) }
        await Self.settle()
        XCTAssertNil(upcoming, "the read waits for the play that is still looking up its songs")

        player.holdLookups = false
        let newer = ["applemusic:song:n1", "applemusic:song:n2", "applemusic:song:n3"]
        try await provider.play(.items(uris: newer, startURI: nil), deviceID: "x")
        try await read.value
        XCTAssertEqual(upcoming, Array(newer.dropFirst()))
        XCTAssertEqual(player.waitingLookups.count, 1, "the replaced play is still looking up")

        player.releaseLookups()
        _ = try? await slow.value
        let after = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(after, Array(newer.dropFirst()), "the replaced play finishing late changes nothing")
    }

    /// A play whose lookup never finishes doesn't hold the read for good: disconnecting lets it
    /// go, and so does the wait limit.
    func testAReadDoesNotWaitForAStalledPlayForever() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player, queueReadWaitLimit: .milliseconds(50))
        player.holdLookups = true
        let stalled = Task { try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x") }
        await Self.settle()
        XCTAssertEqual(player.waitingLookups.count, 1)

        // The wait limit passes while the lookup still hangs.
        _ = try await provider.fetchQueue()
        XCTAssertEqual(player.waitingLookups.count, 1, "the read came back while the play still looks up")

        // Disconnecting releases a waiting read at once.
        let patient = AppleMusicPlaybackProvider(player: player, queueReadWaitLimit: .seconds(600))
        let slow = Task { try await patient.play(.items(uris: Self.uris, startURI: nil), deviceID: "x") }
        await Self.settle()
        var returned = false
        let read = Task { _ = try await patient.fetchQueue(); returned = true }
        await Self.settle()
        XCTAssertFalse(returned)
        try await patient.disconnectPlayer(generation: .initial)
        try await read.value
        XCTAssertTrue(returned)

        // A cancelled read lets go too.
        let again = Task { try await patient.play(.items(uris: Self.uris, startURI: nil), deviceID: "x") }
        await Self.settle()
        let cancelled = Task { _ = try await patient.fetchQueue() }
        await Self.settle()
        cancelled.cancel()
        _ = try? await cancelled.value

        player.releaseLookups()
        _ = try? await stalled.value
        _ = try? await slow.value
        _ = try? await again.value
    }

    /// The play outlasts the read's wait: the panel shows the queue from before, and the list
    /// the play started as soon as the play is in, without another trigger (the app is in the
    /// background, so there's no poll).
    func testAPlayThatOutlastsTheWaitShowsItsListOnceItIsIn() async throws {
        let likedSongs = (1...2_543).map { "applemusic:song:\($0)" }
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player, queueReadWaitLimit: .milliseconds(50))
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        session.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        let queue = QueueViewModel(provider: provider, playbackSession: session)
        queue.setAppActive(false)

        player.holdLookups = true
        let play = Task { try await provider.play(.items(uris: likedSongs, startURI: nil), deviceID: "x") }
        while player.waitingLookups.isEmpty { await Task.yield() }
        await Self.openPanel(queue)
        XCTAssertTrue(queue.upcomingItems.isEmpty, "the wait ran out while the play still looks up")

        player.releaseLookups()
        try await play.value
        let deadline = Date().addingTimeInterval(2)
        while queue.upcomingItems.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.upcomingItems.map(\.uri), Array(likedSongs[1...20]))
    }

    /// What showing the panel does (``QueueViewModel/setPanelVisible(_:)``), awaited.
    private static func openPanel(_ queue: QueueViewModel) async {
        queue.isPanelVisible = true
        await queue.requestQueueRefresh(trigger: .event, allowsHiddenPanel: false)
    }

    // MARK: - Queue book (the live player's queue rules)

    private typealias Book = AppleMusicQueueBook

    private static func row(_ name: String, title: String? = nil) -> Book.Row {
        Book.Row(uri: "applemusic:song:\(name)", title: title ?? name)
    }

    /// Runs one add through the book as the live player does: plan, insert at the planned
    /// position (or right after the current entry), record.
    private static func add(_ row: Book.Row, to queue: inout [Book.Row], current: Int?, book: inout Book) {
        let plan = book.planAdd(row, currentIndex: current, entryCount: queue.count)
        queue.insert(row, at: plan.index ?? (current.map { $0 + 1 } ?? queue.count))
        book.finishAdd(plan)
    }

    /// Spotify keeps added songs ahead of the rest in the order they were added, also once
    /// the first of them plays: adding a, b, playing a, then adding c plays b before c.
    func testAddedSongsStayInOrderAfterTheFirstOneStarts() {
        var queue = ["0", "1", "2"].map { Self.row($0) }
        var book = Book()
        book.replace(with: queue)
        XCTAssertTrue(book.planAdd(Self.row("a"), currentIndex: 0, entryCount: 3).isAfterCurrent,
                      "the first add uses MusicKit's own insert after the current song")
        Self.add(Self.row("a"), to: &queue, current: 0, book: &book)
        Self.add(Self.row("b"), to: &queue, current: 0, book: &book)
        XCTAssertFalse(book.planAdd(Self.row("x"), currentIndex: 0, entryCount: 5).isAfterCurrent,
                       "the next goes to a position past the first")
        XCTAssertEqual(queue.map(\.title), ["0", "a", "b", "1", "2"])
        // a plays.
        Self.add(Self.row("c"), to: &queue, current: 1, book: &book)
        XCTAssertEqual(queue.map(\.title), ["0", "a", "b", "c", "1", "2"], "with a playing, c goes after b")
        // c plays: no added song is ahead any more.
        Self.add(Self.row("d"), to: &queue, current: 3, book: &book)
        XCTAssertEqual(queue.map(\.title), ["0", "a", "b", "c", "d", "1", "2"])
        // The book followed every insert, so each position still names its row.
        for (index, row) in queue.enumerated() {
            XCTAssertEqual(book.rowURI(at: index, title: row.title), row.uri)
        }
    }

    /// Spotify keeps added songs that haven't played when something else starts: they play
    /// right after the new first song, and a later add still goes after them.
    func testAddedSongsSurviveANewPlay() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x")
        try await provider.enqueue(uri: "applemusic:song:a", deviceID: "x")
        try await provider.enqueue(uri: "applemusic:song:b", deviceID: "x")
        try await provider.skipToNext(deviceID: "x")
        player.advance(by: 1) // a plays now; b is still ahead

        try await provider.play(.items(uris: ["applemusic:song:n1", "applemusic:song:n2"], startURI: nil), deviceID: "x")
        try await provider.enqueue(uri: "applemusic:song:c", deviceID: "x")

        let state = try await provider.fetchPlaybackState()
        XCTAssertEqual(state?.item.flatMap(Self.uri), "applemusic:song:n1")
        let upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(upcoming, ["applemusic:song:b", "applemusic:song:c", "applemusic:song:n2"])
    }

    func testTheBookCarriesOnlyTheAddedSongsStillAhead() {
        var book = Book()
        var queue = ["0", "1", "2"].map { Self.row($0) }
        book.replace(with: queue)
        XCTAssertNil(book.addedAhead(of: 0))
        Self.add(Self.row("a"), to: &queue, current: 0, book: &book)
        Self.add(Self.row("b"), to: &queue, current: 0, book: &book)
        XCTAssertEqual(book.addedAhead(of: 0), 1..<3)
        XCTAssertEqual(book.addedAhead(of: 1), 2..<3, "a is playing")
        XCTAssertNil(book.addedAhead(of: 2), "b is playing: nothing added is ahead")
        XCTAssertNil(book.addedAhead(of: nil))
        XCTAssertNil(book.addedAhead(of: 3), "playback moved past the added songs")
        XCTAssertNil(book.addedAhead(of: 40))

        // With shuffle on the carried songs go in after the reshuffle: the run is marked then.
        var shuffled = Book()
        shuffled.replace(with: [])
        shuffled.forgetPositions()
        shuffled.markAdded(start: 3, count: 2)
        XCTAssertEqual(shuffled.planAdd(Self.row("c"), currentIndex: 2, entryCount: 8).index, 5,
                       "a later add goes after the carried songs")
        shuffled.markAdded(start: 3, count: 0)
        XCTAssertNil(shuffled.added)

        book.replace(with: ["n0", "b", "n1"].map { Self.row($0) }, carryingAdded: 1, after: 0)
        XCTAssertEqual(book.added, Book.AddedRun(start: 1, count: 1))
        XCTAssertEqual(book.planAdd(Self.row("c"), currentIndex: 0, entryCount: 3).index, 2)
    }

    /// Nothing is current: MusicKit's own insert starts a queue, and the book knows that one
    /// row only if the queue was empty.
    func testAnAddWithNothingCurrentStartsAQueue() {
        var book = Book()
        let first = book.planAdd(Self.row("a"), currentIndex: nil, entryCount: 0)
        XCTAssertNil(first.index)
        XCTAssertTrue(first.isAfterCurrent)
        book.finishAdd(first)
        XCTAssertEqual(book.rowURI(at: 0, title: "a"), "applemusic:song:a")

        var unknown = Book()
        unknown.finishAdd(unknown.planAdd(Self.row("b"), currentIndex: nil, entryCount: 3))
        XCTAssertNil(unknown.rowURI(at: 0, title: "b"), "a queue the book didn't build: no positions")
    }

    /// Shuffle reorders what plays next, so after turning it on an add goes right after the
    /// current song and no position is trusted any more.
    func testShuffleForgetsThePositions() {
        var queue = ["0", "1", "2"].map { Self.row($0) }
        var book = Book()
        book.replace(with: queue)
        Self.add(Self.row("a"), to: &queue, current: 0, book: &book)
        Self.add(Self.row("b"), to: &queue, current: 0, book: &book)
        book.forgetPositions()
        let plan = book.planAdd(Self.row("c"), currentIndex: 0, entryCount: queue.count)
        XCTAssertEqual(plan.index, 1)
        XCTAssertTrue(plan.isAfterCurrent)
        XCTAssertNil(book.rowURI(at: 1, title: "a"))
    }

    /// A play that replaces the queue while an add waits for MusicKit wins: the add's stale
    /// positions are dropped.
    func testAnAddFinishingAfterANewPlayKeepsTheNewQueuesBook() {
        var book = Book()
        book.replace(with: ["0", "1", "2"].map { Self.row($0) })
        let plan = book.planAdd(Self.row("a"), currentIndex: 0, entryCount: 3)
        let newQueue = ["n0", "n1"].map { Self.row($0) }
        book.replace(with: newQueue)
        book.finishAdd(plan)
        XCTAssertNil(book.added)
        XCTAssertEqual(book.rows, newQueue)
        XCTAssertEqual(book.planAdd(Self.row("b"), currentIndex: 0, entryCount: 2).index, 1)
    }

    /// A slow play (a long playlist's lookup) that finishes after a newer play must not take
    /// the queue back.
    func testAnOlderPlayFinishingLateDoesNotReplaceTheNewerOne() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        player.holdLookups = true
        let slow = Task { try await provider.play(.items(uris: Self.uris, startURI: Self.uris[0]), deviceID: "x") }
        await Self.settle()
        XCTAssertEqual(player.waitingLookups, ["play \(Self.uris[0])"])

        player.holdLookups = false
        try await provider.play(.items(uris: ["applemusic:song:new"], startURI: nil), deviceID: "x")
        player.releaseLookups()
        do {
            try await slow.value
            XCTFail("the overtaken play should give up")
        } catch is CancellationError {}

        let state = try await provider.fetchPlaybackState()
        XCTAssertEqual(state?.item.flatMap(Self.uri), "applemusic:song:new")
    }

    /// Two adds made back to back land in that order even when the first waits for its lookup.
    func testAddsLandInOrderWhenTheFirstWaitsForItsLookup() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x")
        player.holdLookups = true
        let first = Task { try await provider.enqueue(uri: "applemusic:song:a", deviceID: "x") }
        let second = Task { try await provider.enqueue(uri: "applemusic:song:b", deviceID: "x") }
        await Self.settle()
        XCTAssertEqual(player.waitingLookups, ["enqueue applemusic:song:a"], "b waits until a is in")

        player.releaseLookups()
        await Self.settle()
        XCTAssertEqual(player.waitingLookups, ["enqueue applemusic:song:b"])
        player.releaseLookups()
        try await first.value
        try await second.value

        let upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(Array(upcoming.prefix(3)), ["applemusic:song:a", "applemusic:song:b", Self.uris[1]])
    }

    /// An add made while a play still looks its songs up goes into the queue that play starts,
    /// not into the old one it is about to replace.
    func testAnAddDuringAPendingPlayLandsInTheNewQueue() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x")
        player.holdLookups = true
        let newPlaylist = ["applemusic:song:b1", "applemusic:song:b2"]
        let play = Task { try await provider.play(.items(uris: newPlaylist, startURI: nil), deviceID: "x") }
        await Self.settle()
        let add = Task { try await provider.enqueue(uri: "applemusic:song:x", deviceID: "x") }
        await Self.settle()
        XCTAssertEqual(player.waitingLookups, ["play applemusic:song:b1"], "the add waits for the play")

        player.releaseLookups()
        try await play.value
        await Self.settle()
        player.releaseLookups()
        try await add.value

        let state = try await provider.fetchPlaybackState()
        XCTAssertEqual(state?.item.flatMap(Self.uri), "applemusic:song:b1")
        let upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(upcoming, ["applemusic:song:x", "applemusic:song:b2"])
    }

    /// Two entries that look the same (title, artist and length) keep the rows they were queued
    /// from: the queue position decides, as long as the entry there still shows that title.
    func testLookAlikeEntriesKeepTheRowsTheyWereQueuedFrom() {
        var book = Book()
        book.replace(with: [Self.row("standard", title: "Halo"), Self.row("deluxe", title: "Halo")])
        XCTAssertEqual(book.rowURI(at: 0, title: "Halo"), "applemusic:song:standard")
        XCTAssertEqual(book.rowURI(at: 1, title: "Halo"), "applemusic:song:deluxe")
        XCTAssertNil(book.rowURI(at: 1, title: "Single Ladies"), "the queue changed under us: fall back to the keys")
        XCTAssertNil(book.rowURI(at: 2, title: "Halo"))
        XCTAssertNil(book.rowURI(at: nil, title: "Halo"))
    }

    /// Shuffle reorders the queue, so positions stop counting, but the entries keep their ids:
    /// noted before the shuffle, the id still finds the right one of two look-alike rows.
    func testLookAlikeEntriesKeepTheirRowsThroughShuffle() {
        var book = Book()
        book.replace(with: [Self.row("standard", title: "Halo"), Self.row("deluxe", title: "Halo")])
        book.noteEntries(ids: ["e1", "e2"], titles: ["Halo", "Halo"])
        book.forgetPositions()
        // Shuffled: e2 now sits first.
        XCTAssertEqual(book.rowURI(entryID: "e2", at: 0, title: "Halo"), "applemusic:song:deluxe")
        XCTAssertEqual(book.rowURI(entryID: "e1", at: 1, title: "Halo"), "applemusic:song:standard")
        XCTAssertNil(book.rowURI(entryID: "e9", at: 0, title: "Halo"), "unknown id, no positions: the keys decide")
        book.replace(with: [])
        XCTAssertNil(book.rowURI(entryID: "e1", at: nil, title: "Halo"), "a new play forgets the old ids")
    }

    /// After shuffle the ids give the positions back, so a look-alike song added then still
    /// gets its own row.
    func testALookAlikeAddedAfterShuffleKeepsItsRow() {
        var book = Book()
        book.replace(with: [Self.row("standard", title: "Halo"), Self.row("x"), Self.row("y")])
        book.noteEntries(ids: ["e1", "e2", "e3"], titles: ["Halo", "x", "y"])
        book.forgetPositions()
        // Shuffled: [y, Halo, x], Halo (e1) plays.
        book.noteEntries(ids: ["e3", "e1", "e2"], titles: ["y", "Halo", "x"])
        let plan = book.planAdd(Self.row("deluxe", title: "Halo"), currentIndex: 1, entryCount: 3)
        XCTAssertEqual(plan.index, 2)
        book.finishAdd(plan)
        // The added entry still has MusicKit's temporary id: its position decides.
        XCTAssertEqual(book.rowURI(entryID: "temp", at: 2, title: "Halo"), "applemusic:song:deluxe")
        XCTAssertEqual(book.rowURI(entryID: "e1", at: 1, title: "Halo"), "applemusic:song:standard")
        // Its final id is noted by position on the next read and finds it from then on.
        book.noteEntries(ids: ["e3", "e1", "final", "e2"], titles: ["y", "Halo", "Halo", "x"])
        XCTAssertEqual(book.rowURI(entryID: "final", at: nil, title: "Halo"), "applemusic:song:deluxe")
    }

    /// Two recordings with the same title and artist are told apart by their length; one
    /// recording whose length reads slightly differently still matches on title and artist.
    func testQueuedEntriesWithTheSameTitleAndArtistKeepTheirOwnRows() {
        let keys = MusicKitApplicationPlayer.entryKeys
        let standard = keys("Halo", "Beyoncé", 261)
        let deluxe = keys("Halo", "Beyoncé", 284)
        XCTAssertNotEqual(standard.first, deluxe.first)
        XCTAssertEqual(standard.last, deluxe.last)
        XCTAssertEqual(keys("Halo", "Beyoncé", nil), [standard.last!])
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testMusicKitFailuresSurfaceAsAppleMusicErrors() async {
        let player = ScriptedAppleMusicPlayer()
        player.failure = URLError(.notConnectedToInternet)
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        session.setConnectionState(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))

        await session.play(uri: Self.uris[0])

        guard case let .error(displayError) = session.connectionState else {
            return XCTFail("Expected an error, got \(session.connectionState)")
        }
        XCTAssertEqual(displayError.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))
        XCTAssertFalse(displayError.message.contains("Spotify"))
    }

    // MARK: - Songs this Mac won't play (#429)

    /// The first songs of "Your top tracks" as they came from MusicKit when #429 was reported.
    /// On a Mac that only allows clean music, MusicKit refused the explicit one with
    /// `MPMusicPlayerControllerErrorDomain` code 6 and the whole list failed with "try again".
    private static func topTracks() throws -> [(uri: String, entry: MusicPlayer.Queue.Entry)] {
        try [
            AppleMusicFixtures.song(id: "1712562731", title: "Slowww"),
            AppleMusicFixtures.song(id: "1772940995", title: "Poesia Acústica #12 Pra Sempre", explicit: true),
            AppleMusicFixtures.song(id: "1689834069", title: "Te Peço Pra Ficar"),
            AppleMusicFixtures.song(id: "1880570626", title: "7:44", explicit: true),
        ].map { (AppleMusicItemMapping.track($0).uri, MusicPlayer.Queue.Entry($0)) }
    }

    func testAMacThatOnlyAllowsCleanMusicPlaysTheCleanSongsOfAList() throws {
        let songs = try Self.topTracks()
        let kept = try MusicKitApplicationPlayer.leavingOutBlocked(
            songs, startURI: "applemusic:song:1712562731", explicitBlocked: true
        )
        XCTAssertEqual(kept.map(\.uri), ["applemusic:song:1712562731", "applemusic:song:1689834069"])
        // A list started from its header leaves them out too.
        XCTAssertEqual(try MusicKitApplicationPlayer.leavingOutBlocked(songs, startURI: nil, explicitBlocked: true).count, 2)
        // Without the restriction nothing changes.
        XCTAssertEqual(
            try MusicKitApplicationPlayer.leavingOutBlocked(songs, startURI: nil, explicitBlocked: false).map(\.uri),
            songs.map(\.uri)
        )
    }

    func testAnExplicitSongOnAMacThatOnlyAllowsCleanMusicSaysWhy() throws {
        let songs = try Self.topTracks()
        XCTAssertThrowsError(try MusicKitApplicationPlayer.leavingOutBlocked(
            songs, startURI: "applemusic:song:1772940995", explicitBlocked: true
        )) { error in
            XCTAssertEqual((error as? MusicPlaybackError)?.reason, .explicitContentRestricted)
        }
        // A list of only explicit songs (an album) has nothing to play.
        XCTAssertThrowsError(try MusicKitApplicationPlayer.leavingOutBlocked(
            songs.filter { $0.uri.hasSuffix("0995") || $0.uri.hasSuffix("0626") }, startURI: nil, explicitBlocked: true
        )) { error in
            XCTAssertEqual((error as? MusicPlaybackError)?.reason, .explicitContentRestricted)
        }

        let display = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .explicitContentRestricted)
        )
        XCTAssertEqual(display.title, SpotiglassL10n.string("error.playback.appleMusic.explicit.title"))
        XCTAssertEqual(display.message, SpotiglassL10n.string("error.playback.appleMusic.explicit.message"))
        XCTAssertNil(display.recoveryAction, "Reconnecting doesn't change what this Mac allows")
    }

    /// Songs added with Add to queue before the Mac started blocking explicit music come along
    /// into the next queue; the explicit ones would stop it there, so they are dropped quietly.
    func testSongsAddedBeforeTheRestrictionLeaveOutTheExplicitOnes() throws {
        let added = try Self.topTracks()
        XCTAssertEqual(
            MusicKitApplicationPlayer.droppingBlocked(added, explicitBlocked: true).map(\.uri),
            ["applemusic:song:1712562731", "applemusic:song:1689834069"]
        )
        // Only explicit ones added: nothing comes along, and the new queue still plays.
        XCTAssertTrue(MusicKitApplicationPlayer.droppingBlocked(
            added.filter { $0.uri.hasSuffix("0995") || $0.uri.hasSuffix("0626") }, explicitBlocked: true
        ).isEmpty)
        XCTAssertEqual(MusicKitApplicationPlayer.droppingBlocked(added, explicitBlocked: false).count, added.count)
    }

    // MARK: - Starts MusicKit refuses (#476)

    /// The first songs of "Your top tracks" as MusicKit listed them when #476 was reported:
    /// catalog songs with play parameters. "oh yeah?" is the one that failed.
    private static func refusedTopTracks() throws -> [MusicPlayer.Queue.Entry] {
        try [
            AppleMusicFixtures.song(id: "1745213459", title: "ITTY BITTY", artist: "Mishaal Tamer", album: "ITTY BITTY - Single", durationMs: 143_000, explicit: true),
            AppleMusicFixtures.song(id: "1783862517", title: "Loca Playa", artist: "Santax", album: "Loca Playa", durationMs: 174_000),
            AppleMusicFixtures.song(id: "6773775282", title: "oh yeah?", artist: "Steve Lacy", album: "Oh yeah?", durationMs: 170_000, explicit: true),
            AppleMusicFixtures.song(id: "1838552993", title: "Where's Your Head At", artist: "Eurotripp", album: "Where's Your Head At", durationMs: 186_000),
        ].map { MusicPlayer.Queue.Entry($0) }
    }

    private typealias Starts = AppleMusicQueueStarts<String>

    /// One press through `starts`: the pressed queue's rows are `rows`, the rows of what the
    /// player holds now are `holding`.
    private static func press(
        _ starts: Starts,
        _ entries: [MusicPlayer.Queue.Entry],
        at index: Int = 0,
        rows: String,
        holding: String = "P"
    ) async throws -> Starts.Started {
        try await starts.start(entries, at: index, currentRows: holding, rowsPlayed: { _ in rows })
    }

    /// What a press left in the player: "plays" for a start MusicKit took, else what the refused
    /// start gave back.
    private static func outcome(_ work: () async throws -> Starts.Started) async -> String {
        do {
            let started = try await work()
            return "plays, \(started.leftOut) left out"
        } catch let refused as Starts.Refused {
            switch refused.left {
            case let .previousQueue(rows, leftOutBefore): return "gave back \(rows), \(leftOutBefore) left out"
            case .nothing: return "nothing"
            case .replaced: return "replaced"
            }
        } catch {
            return "failed: \(error)"
        }
    }

    /// P: ITTY BITTY and Loca Playa, ITTY BITTY playing at 0:42.
    private static func playingP(_ player: RefusingQueueStarter) async throws {
        let songs = try refusedTopTracks()
        player.setQueue([songs[0], songs[1]], startingAt: nil)
        try await player.play()
        player.playbackTime = 42
    }

    /// #476: one song pressed on its own (a search result, the palette, a single row). MusicKit
    /// refused such a queue about half the time when it named the start song ("Prepare queue
    /// failed with unexpected start item"), and the bar went to "Paused" at 0:00. A start that is
    /// the first song isn't named, so it plays.
    func testASongPressedOnItsOwnPlays() async throws {
        let ohYeah = try Self.refusedTopTracks()[2]
        let player = RefusingQueueStarter(refusesNamedStart: true)
        let starts = Starts(player: player)

        let started = try await Self.press(starts, [ohYeah], rows: "oh yeah")

        XCTAssertEqual(started.leftOut, 0)
        XCTAssertTrue(starts.holdsQueue(started))
        XCTAssertEqual(player.currentEntry?.title, "oh yeah?")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.namedStarts, [nil], "the first song is never named as the start")
    }

    /// The same refusal with the pressed song further down a list: the start tries again with
    /// the list from the pressed song on, which MusicKit takes, so the song plays.
    func testAPressedRowPlaysWhenMusicKitRefusesTheNamedStart() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusesNamedStart: true)

        let started = try await Self.press(Starts(player: player), songs, at: 2, rows: "top tracks")

        XCTAssertEqual(started.leftOut, 2)
        XCTAssertEqual(player.currentEntry?.title, "oh yeah?")
        XCTAssertEqual(player.entries.map(\.title), ["oh yeah?", "Where's Your Head At"])
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.namedStarts, ["oh yeah?", nil])
    }

    /// A start MusicKit takes is set once, with the songs before the pressed one kept.
    func testAPressedRowKeepsTheSongsBeforeItWhenMusicKitTakesIt() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter()

        let started = try await Self.press(Starts(player: player), songs, at: 2, rows: "top tracks")

        XCTAssertEqual(started.leftOut, 0)
        XCTAssertEqual(player.entries.count, 4)
        XCTAssertEqual(player.currentEntry?.title, "oh yeah?")
        XCTAssertEqual(player.namedStarts, ["oh yeah?"])
    }

    /// A song MusicKit won't play at all, pressed while ITTY BITTY was playing. MusicKit took
    /// the new queue, refused it, and was left on "oh yeah?" paused at 0:00. The start gives
    /// back ITTY BITTY, where it was, still playing, with its rows.
    func testASongThatCantPlayGivesBackWhatWasPlaying() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        try await Self.playingP(player)
        let starts = Starts(player: player)

        let outcome = await Self.outcome { try await Self.press(starts, songs, at: 2, rows: "top tracks") }

        XCTAssertEqual(outcome, "gave back P, 0 left out")
        XCTAssertEqual(player.currentEntry?.title, "ITTY BITTY")
        XCTAssertEqual(player.entries.map(\.title), ["ITTY BITTY", "Loca Playa"])
        XCTAssertTrue(player.isPlaying, "it was playing, so it plays on")
        XCTAssertEqual(player.playbackTime, 42)
        XCTAssertFalse(starts.hidesRefusedQueue)
    }

    /// A paused song comes back paused at its position: loaded, not played. MusicKit also refuses
    /// to name it as the start, so it comes back with the songs from it on.
    func testASongThatCantPlayLeavesAPausedSongPaused() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        player.setQueue([songs[0], songs[1], songs[3]], startingAt: songs[1])
        player.playbackTime = 95
        player.refusesNamedStart = true

        let outcome = await Self.outcome { try await Self.press(Starts(player: player), [songs[2]], rows: "oh yeah") }

        XCTAssertEqual(outcome, "gave back P, 1 left out")
        XCTAssertEqual(player.currentEntry?.title, "Loca Playa")
        XCTAssertEqual(player.entries.map(\.title), ["Loca Playa", "Where's Your Head At"])
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackTime, 95)
        XCTAssertEqual(player.commands.filter { $0 == "play" }.count, 1, "only the refused start played")
    }

    /// The refused song was the first thing played: there is nothing to give back, so the
    /// player is stopped and the bar shows nothing loaded, never the song as "Paused". The
    /// refused song MusicKit still holds is then nothing to give back either, and a start that
    /// plays shows again.
    func testASongThatCantPlayFirstLeavesNothingLoaded() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282", "1838552993"])
        let starts = Starts(player: player)

        let first = await Self.outcome { try await Self.press(starts, songs, at: 2, rows: "top tracks", holding: "none") }
        XCTAssertEqual(first, "nothing")
        XCTAssertEqual(player.commands.last, "stop")
        XCTAssertTrue(starts.hidesRefusedQueue)

        let second = await Self.outcome { try await Self.press(starts, [songs[3]], rows: "Where's Your Head At", holding: "hidden") }
        XCTAssertEqual(second, "nothing", "the hidden refused song doesn't come back as Paused")
        XCTAssertTrue(starts.hidesRefusedQueue)
        starts.playerPlays() // a media key started it after all
        XCTAssertFalse(starts.hidesRefusedQueue, "what plays shows")
        _ = await Self.outcome { try await Self.press(starts, [songs[3]], rows: "Where's Your Head At", holding: "hidden") }
        XCTAssertTrue(starts.hidesRefusedQueue)

        _ = try await Self.press(starts, [songs[1]], rows: "Loca Playa", holding: "hidden")
        XCTAssertFalse(starts.hidesRefusedQueue)
    }

    /// The old song is refused too when it comes back: nothing could be given back, so the
    /// player stops instead of showing what it last took as "Paused".
    func testAGiveBackMusicKitRefusesTooLeavesNothingLoaded() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282", "1783862517"])
        player.setQueue([songs[0], songs[1]], startingAt: songs[1])
        player.playbackTime = 95
        let starts = Starts(player: player)

        let outcome = await Self.outcome { try await Self.press(starts, [songs[2]], rows: "oh yeah") }

        XCTAssertEqual(outcome, "nothing")
        XCTAssertEqual(player.commands.last, "stop")
        XCTAssertTrue(starts.hidesRefusedQueue)
    }

    /// I press another song while the refused one's old queue is being given back (the press
    /// failed, so I press again). The newer play owns the queue: it keeps its song at 0:00, and
    /// the old song's position isn't written onto it.
    func testAPlayPressedWhileTheOldQueueIsGivenBackKeepsItsSong() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        try await Self.playingP(player)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, songs, at: 2, rows: "X") } }
        await player.waitForHeldPlays(1)
        player.releasePlay() // refused at its named start
        await player.waitForHeldPlays(1)
        player.releasePlay() // refused from the pressed song on
        await player.waitForHeldPlays(1) // P going back
        XCTAssertEqual(player.currentEntry?.title, "ITTY BITTY")
        let y = Task { try await Self.press(starts, [songs[3]], rows: "Y", holding: "X") }
        await player.waitForHeldPlays(2)
        player.releasePlay()
        player.releasePlay()

        let xOutcome = await x.value
        let yStarted = try await y.value
        XCTAssertEqual(xOutcome, "replaced")
        XCTAssertTrue(starts.holdsQueue(yStarted))
        XCTAssertEqual(player.currentEntry?.title, "Where's Your Head At")
        XCTAssertEqual(player.playbackTime, 0, "the old song's 0:42 stays with the old song")
    }

    /// P plays at 0:42. I press X, and press Y while MusicKit still works on X (it already holds
    /// X's queue). Both are refused. Y gives back P, playing at 0:42, not X, which never played.
    func testOverlappingRefusedPressesGiveBackWhatLastPlayed() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282", "1838552993"])
        try await Self.playingP(player)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X") } }
        await player.waitForHeldPlays(1)
        let y = Task { await Self.outcome { try await Self.press(starts, [songs[3]], rows: "Y", holding: "X") } }
        await player.waitForHeldPlays(2)
        player.releasePlay() // X refused
        player.releasePlay() // Y refused
        await player.waitForHeldPlays(1) // P going back
        player.releasePlay()

        let xOutcome = await x.value
        let yOutcome = await y.value
        XCTAssertEqual(xOutcome, "replaced")
        XCTAssertEqual(yOutcome, "gave back P, 0 left out")
        XCTAssertEqual(player.currentEntry?.title, "ITTY BITTY")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playbackTime, 42)
    }

    /// The same, when MusicKit plays X while Y still waits: X is what Y gives back. And when the
    /// first press of the session had left nothing loaded, X now shows.
    func testARefusedPressGivesBackAnEarlierPressThatPlayedMeanwhile() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["1838552993", "1745213459"])
        let starts = Starts(player: player)
        let first = await Self.outcome { try await Self.press(starts, [songs[0]], rows: "ITTY BITTY", holding: "none") }
        XCTAssertEqual(first, "nothing")
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X", holding: "hidden") } }
        await player.waitForHeldPlays(1)
        let y = Task { await Self.outcome { try await Self.press(starts, [songs[3]], rows: "Y", holding: "X") } }
        await player.waitForHeldPlays(2)
        player.releasePlay() // X plays
        player.releasePlay() // Y refused
        await player.waitForHeldPlays(1) // X going back
        player.releasePlay()

        let xOutcome = await x.value
        let yOutcome = await y.value
        XCTAssertEqual(xOutcome, "plays, 0 left out")
        XCTAssertEqual(yOutcome, "gave back X, 0 left out")
        XCTAssertEqual(player.currentEntry?.title, "oh yeah?")
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(starts.hidesRefusedQueue, "what plays shows")
    }

    /// A sign-out stops the player while a start waits for MusicKit: the start leaves the
    /// stopped player alone, whatever MusicKit then answers.
    func testAStopWhileAStartWaitsLeavesThePlayerStopped() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        try await Self.playingP(player)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, songs, at: 2, rows: "X") } }
        await player.waitForHeldPlays(1)
        starts.stop()
        let commandsAtStop = player.commands.count
        player.releasePlay()

        let xOutcome = await x.value
        XCTAssertEqual(xOutcome, "replaced")
        XCTAssertEqual(Array(player.commands.dropFirst(commandsAtStop)), [], "no queue is set after the stop")
        XCTAssertFalse(player.isPlaying)
    }

    /// The same when MusicKit starts the song anyway once the stop went out: it is stopped
    /// again, so nothing plays after a sign-out.
    func testAStartMusicKitPlaysAfterAStopIsStoppedAgain() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter()
        try await Self.playingP(player)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X") } }
        await player.waitForHeldPlays(1)
        starts.stop()
        player.releasePlay()

        let xOutcome = await x.value
        XCTAssertEqual(xOutcome, "plays, 0 left out")
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.commands.suffix(3), ["play", "stop", "stop"], "the sign-out's stop, then the stop after MusicKit started it")
    }

    /// MusicKit keeps its queue after a stop (a sign-out). A refused press after that gives
    /// back nothing, not the ended session's song.
    func testARefusedPressAfterAStopGivesBackNothing() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        try await Self.playingP(player)
        let starts = Starts(player: player)
        starts.stop()

        let outcome = await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X", holding: "ended session") }

        XCTAssertEqual(outcome, "nothing")
        XCTAssertNotEqual(player.currentEntry?.title, "ITTY BITTY")
    }

    /// P plays. I press X and pause while MusicKit still works on it. X is refused for good:
    /// P comes back paused at its position, since pause was the last thing I asked for.
    func testAPauseWhileAStartWaitsKeepsTheGiveBackPaused() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        try await Self.playingP(player)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X") } }
        await player.waitForHeldPlays(1)
        starts.paused()
        player.releasePlay() // X refused
        await player.waitForHeldPlays(1) // P going back
        player.releasePlay()

        let xOutcome = await x.value
        XCTAssertEqual(xOutcome, "gave back P, 0 left out")
        XCTAssertEqual(player.currentEntry?.title, "ITTY BITTY")
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackTime, 42)
        XCTAssertEqual(player.commands.last, "prepare", "loaded, not played")
    }

    /// Right after a refusal hides the refused song, MusicKit can still report the music it
    /// played before for a moment. That doesn't show the refused song as Paused; a report once
    /// that has settled (a media key started it) does show it.
    func testAPlayingReportRightAfterHidingKeepsItHidden() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusing: ["6773775282"])
        let starts = Starts(player: player)
        _ = await Self.outcome { try await Self.press(starts, [songs[2]], rows: "X", holding: "none") }
        XCTAssertTrue(starts.hidesRefusedQueue)

        starts.playerReportsPlaying(now: Date())
        XCTAssertTrue(starts.hidesRefusedQueue, "MusicKit's state trailing the stop")

        starts.playerReportsPlaying(now: Date().addingTimeInterval(Starts.reportSettle + 0.5))
        XCTAssertFalse(starts.hidesRefusedQueue)
    }

    /// I press a row further down a short list and pause while MusicKit works on it. MusicKit
    /// refuses the named start and the retry plays the song: it is paused again, since pause
    /// was the last thing I asked for.
    func testAPauseBeforeTheRetryKeepsTheSongPaused() async throws {
        let songs = try Self.refusedTopTracks()
        let player = RefusingQueueStarter(refusesNamedStart: true)
        let starts = Starts(player: player)
        player.holdsPlays = true

        let x = Task { await Self.outcome { try await Self.press(starts, songs, at: 2, rows: "X") } }
        await player.waitForHeldPlays(1)
        starts.paused()
        player.releasePlay() // the named start refused
        await player.waitForHeldPlays(1) // the retry from the pressed song
        player.releasePlay()

        let xOutcome = await x.value
        XCTAssertEqual(xOutcome, "plays, 2 left out")
        XCTAssertEqual(player.currentEntry?.title, "oh yeah?")
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.commands.last, "pause")
    }

    /// A refused start gave back the queue the book held before. An add planned against that
    /// queue before the press went into another queue in MusicKit, so it isn't recorded.
    func testAnAddPlannedBeforeAGiveBackIsIgnored() {
        var book = Book()
        book.replace(with: ["a", "b", "c"].map { Self.row($0) })
        let plan = book.planAdd(Self.row("z"), currentIndex: 0, entryCount: 3)

        book.forgetPendingAdds()
        book.finishAdd(plan)

        XCTAssertNil(book.addedAhead(of: 0))
        XCTAssertEqual(book.rowURI(at: 1, title: "b"), Self.row("b").uri)
    }

    /// A refused start can only put the old queue back from its current song on ([A, B, X, Y, C]
    /// with B playing and X, Y added comes back as [B, X, Y, C]). The added songs keep their
    /// place: a later add goes after them, and the next play still carries them.
    func testAQueuePutBackWithoutItsFirstSongsKeepsTheAddedSongs() {
        var book = Book()
        var queue = ["a", "b", "c"].map { Self.row($0) }
        book.replace(with: queue)
        Self.add(Self.row("x"), to: &queue, current: 1, book: &book)
        Self.add(Self.row("y"), to: &queue, current: 1, book: &book)
        XCTAssertEqual(queue.map(\.title), ["a", "b", "x", "y", "c"])

        book.dropFirst(1)

        XCTAssertEqual(book.addedAhead(of: 0), 1..<3, "x and y are still the added songs")
        XCTAssertEqual(book.planAdd(Self.row("z"), currentIndex: 0, entryCount: 4).index, 3, "z goes after x and y")
        XCTAssertEqual(book.rowURI(at: 0, title: "b"), Self.row("b").uri)
        XCTAssertEqual(book.rowURI(at: 3, title: "c"), Self.row("c").uri)

        var past = Book()
        past.replace(with: ["a", "b", "c"].map { Self.row($0) }, carryingAdded: 1, after: 0)
        past.dropFirst(2)
        XCTAssertNil(past.addedAhead(of: 0), "the added song was before the song that plays on")
    }

    /// What Screen Time ("Music: Clean") and a restrictions profile set, and the same keys saved
    /// as ordinary preferences, which don't stop MusicKit from playing anything.
    func testOnlyAnEnforcedRestrictionBlocksExplicitSongs() {
        func lookup(_ values: [String: (Any, Bool)]) -> AppleMusicContentRestrictions.Lookup {
            { key, _ in values[key].map { ($0.0, $0.1) } ?? (nil, false) }
        }
        XCTAssertTrue(AppleMusicContentRestrictions.isExplicitMusicBlocked(
            lookup: lookup(["restrictExplicit": (true, true)])
        ), "Screen Time's Clean")
        XCTAssertTrue(AppleMusicContentRestrictions.isExplicitMusicBlocked(
            lookup: lookup(["allowExplicitContent": (false, true)])
        ), "A restrictions profile")
        XCTAssertFalse(AppleMusicContentRestrictions.isExplicitMusicBlocked(
            lookup: lookup(["restrictExplicit": (true, false), "allowExplicitContent": (false, false)])
        ), "Saved but not enforced")
        XCTAssertFalse(AppleMusicContentRestrictions.isExplicitMusicBlocked(
            lookup: lookup(["restrictExplicit": (false, true), "allowExplicitContent": (true, true)])
        ), "Enforced, but explicit allowed")
        XCTAssertFalse(AppleMusicContentRestrictions.isExplicitMusicBlocked(lookup: lookup([:])))
    }

    /// The error MusicKit gave for the explicit top track. Trying again gives the same answer,
    /// so the message says the song can't play instead of "try again in a moment".
    func testMusicKitRefusingASongSaysItCantPlay() async {
        let refused = NSError(
            domain: "MPMusicPlayerControllerErrorDomain",
            code: 6,
            userInfo: [NSDebugDescriptionErrorKey: "Failed to prepare to play"]
        )
        XCTAssertEqual(MusicKitApplicationPlayer.playerError(refused).reason, .notFound)
        XCTAssertEqual(MusicKitApplicationPlayer.playerError(NSError(domain: "Other", code: 6)).reason, .failed)

        let player = ScriptedAppleMusicPlayer()
        player.failure = MusicKitApplicationPlayer.playerError(refused)
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        session.setConnectionState(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))

        await session.playFromPlaylist(clickedURI: Self.uris[1], playableURIs: Self.uris)

        guard case let .error(displayError) = session.connectionState else {
            return XCTFail("Expected an error, got \(session.connectionState)")
        }
        XCTAssertEqual(displayError.message, SpotiglassL10n.string("error.playback.appleMusic.notPlayable"))
        XCTAssertNil(displayError.recoveryAction)
    }

    /// #430: a play that MusicKit refused put "Reconnect playback / Connects Spotiglass to
    /// Apple Music again" in the bar. Apple Music's player is this Mac, so there is nothing to
    /// reconnect, and no Spotify device to retry: every error it shows offers no button.
    /// Spotify keeps Reconnect for a web player that really dropped, and a failed command
    /// there offers Retry, never Reconnect.
    func testPlayerBarOffersReconnectOnlyForASpotifyPlayerThatLostItsConnection() async {
        let player = ScriptedAppleMusicPlayer()
        player.failure = NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6)
        let appleMusic = PlaybackSessionViewModel(provider: AppleMusicPlaybackProvider(player: player))
        appleMusic.deviceID = AppleMusicPlaybackProvider.deviceID
        appleMusic.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        appleMusic.setConnectionState(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        XCTAssertFalse(appleMusic.canReconnectPlayer)

        await appleMusic.play(uri: Self.uris[0])
        guard case let .error(failedPlay) = appleMusic.connectionState else {
            return XCTFail("Expected an error, got \(appleMusic.connectionState)")
        }
        XCTAssertEqual(failedPlay.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))
        XCTAssertNil(failedPlay.recoveryAction, "Apple Music has no connection to reconnect")

        // The errors the session raises for any player (no device yet, a connect that timed
        // out, a raw error from a command) offer nothing either.
        for error in [
            PlaybackSessionViewModel.playbackDeviceNotReadyError(),
            PlaybackSessionViewModel.playbackDeviceReconnectRequiredError(),
            PlaybackSessionViewModel.playbackHostConnectionTimedOutError(),
            PlaybackSessionViewModel.displayError(for: CocoaError(.fileReadUnknown)),
        ] {
            appleMusic.setConnectionState(.error(error))
            guard case let .error(shown) = appleMusic.connectionState else { return XCTFail("Expected an error") }
            XCTAssertNil(shown.recoveryAction, error.message)
            XCTAssertFalse(shown.message.contains("Reconnect"), shown.message)
            XCTAssertFalse(shown.message.contains("Spotify"), shown.message)
        }

        // The bar's text before Apple Music starts doesn't point at Reconnect either.
        let disconnected = PlaybackControlsView.serviceString(
            "playback.controls.state.disconnected.subtitle",
            appleMusic: "playback.controls.state.disconnected.subtitle.appleMusic",
            service: .appleMusic
        )
        XCTAssertFalse(disconnected.contains("Reconnect"), disconnected)

        let spotify = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        XCTAssertTrue(spotify.canReconnectPlayer)
        // Play before the web player reported its device: the player isn't connected.
        await spotify.play(uri: "spotify:track:1")
        guard case let .error(notConnected) = spotify.connectionState else {
            return XCTFail("Expected an error, got \(spotify.connectionState)")
        }
        XCTAssertEqual(notConnected.recoveryAction, .reconnect)
        spotify.setConnectionState(.error(PlaybackSessionViewModel.playbackHostConnectionTimedOutError()))
        guard case let .error(timedOut) = spotify.connectionState else { return XCTFail("Expected an error") }
        XCTAssertEqual(timedOut.recoveryAction, .reconnect)
        // A command Spotify refused leaves the player connected: Retry, not Reconnect.
        let failedCommand = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.network("offline"))
        spotify.setConnectionState(.error(failedCommand))
        guard case let .error(retry) = spotify.connectionState else { return XCTFail("Expected an error") }
        XCTAssertEqual(retry.recoveryAction, .retryTransfer)
    }

    /// #430, the other half: on main the failed command's Reconnect was the only way out of
    /// the error, because it restarted the player. Without the button, a Next that MusicKit
    /// refused while a song kept playing left the bar on the error with Play, Previous and
    /// Next off and polling stopped, until another song was started from the library. The
    /// bar shows the message, then reads the player again and gives the song and its
    /// controls back by itself.
    func testAppleMusicBarComesBackToThePlayingSongAfterACommandFails() async throws {
        // A refused Next, and a Next to songs this Mac blocks (only clean music allowed, #429).
        let failures: [(MusicPlaybackError.Reason, String)] = [
            (.failed, "error.playback.appleMusic.failed"),
            (.explicitContentRestricted, "error.playback.appleMusic.explicit.message"),
        ]
        for (reason, messageKey) in failures {
            let (player, session) = try await Self.playingSession(passingErrorRecoveryDelay: .milliseconds(20))
            try await Self.read(session, player, at: 30)
            XCTAssertTrue(Self.isPlaying(session))

            player.skipFailure = MusicPlaybackError(service: .appleMusic, reason: reason, detail: "MPMusicPlayerControllerErrorDomain 6")
            await session.next()
            guard case let .error(failed) = session.connectionState else {
                return XCTFail("Expected the failed Next to show, got \(session.connectionState)")
            }
            XCTAssertNil(failed.recoveryAction)
            XCTAssertEqual(failed.message, SpotiglassL10n.string(messageKey))
            XCTAssertFalse(session.isTransportMutationReady, "the error is on screen for a moment")

            player.advance(by: 1)
            await session.passingErrorRecoveryTask?.value
            XCTAssertTrue(Self.isPlaying(session), "\(reason): the bar stayed on the error: \(session.connectionState)")
            XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
            XCTAssertTrue(session.isTransportMutationReady, "\(reason): Play, Previous and Next work again")
        }
    }

    /// A song that can't play, double-clicked while the bar still shows the failed Next,
    /// replaces that error. The player is still the one that worked, so the bar comes back
    /// from the second error too instead of staying on it.
    func testAppleMusicBarComesBackWhenASecondFailureReplacesTheFirst() async throws {
        let (player, session) = try await Self.playingSession(passingErrorRecoveryDelay: .milliseconds(300))
        try await Self.read(session, player, at: 30)
        player.skipFailure = MusicPlaybackError(service: .appleMusic, reason: .notFound)
        await session.next()
        XCTAssertNotNil(session.passingErrorRecoveryTask)

        player.failure = NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6)
        await session.play(uri: Self.uris[3])
        guard case let .error(second) = session.connectionState else {
            return XCTFail("Expected the failed play to show, got \(session.connectionState)")
        }
        XCTAssertEqual(second.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))

        await session.passingErrorRecoveryTask?.value
        XCTAssertTrue(Self.isPlaying(session), "the bar stayed on the second error: \(session.connectionState)")
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
    }

    /// A subscription message stays, but once the subscription is back, a song that then
    /// fails for a moment recovers like any other: the bar doesn't stay on that error.
    func testAppleMusicMomentaryFailureAfterAPersistentErrorStillRecovers() async throws {
        let (player, session) = try await Self.playingSession(passingErrorRecoveryDelay: .milliseconds(20))
        try await Self.read(session, player, at: 30)
        player.skipFailure = MusicPlaybackError(service: .appleMusic, reason: .subscriptionRequired(message: nil))
        await session.next()
        XCTAssertNil(session.passingErrorRecoveryTask)

        player.failure = NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6)
        await session.play(uri: Self.uris[3])
        XCTAssertNotNil(session.passingErrorRecoveryTask, "the momentary failure that followed must recover")
        await session.passingErrorRecoveryTask?.value
        XCTAssertTrue(Self.isPlaying(session), "the bar stayed on the error: \(session.connectionState)")
    }

    /// A play chosen while the failed Next still shows, and still looking up its songs when
    /// the recovery is due: the recovery waits for it instead of putting the old song (or
    /// "Ready") back under it, and once the play is through, the next read shows its song.
    func testAppleMusicRecoveryWaitsForAPlayStillRunning() async throws {
        // Long enough that the held play is surely running before the recovery is due, even on
        // a busy machine; the wait below is well past it.
        let (player, session) = try await Self.playingSession(passingErrorRecoveryDelay: .milliseconds(300))
        try await Self.read(session, player, at: 30)
        player.skipFailure = MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "refused")
        await session.next()
        guard case let .error(failed) = session.connectionState else { return XCTFail("Expected the failed Next") }

        player.holdLookups = true
        let play = Task { await session.play(uri: Self.uris[3]) }
        while player.waitingLookups.isEmpty { await Task.yield() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.connectionState, .error(failed), "the recovery ran under the running play")

        player.releaseLookups()
        await play.value
        player.advance(by: 1)
        await session.syncTransportFromSpotify()
        XCTAssertTrue(Self.isPlaying(session), "\(session.connectionState)")
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[3])
    }

    /// Access turned off in System Settings or a lapsed subscription is not a passing
    /// failure: the bar keeps saying so instead of going back to controls that fail again.
    func testAppleMusicAccessAndSubscriptionErrorsStayOnScreen() async throws {
        for reason in [MusicPlaybackError.Reason.missingPermission, .subscriptionRequired(message: nil)] {
            let (player, session) = try await Self.playingSession(passingErrorRecoveryDelay: .milliseconds(20))
            player.skipFailure = MusicPlaybackError(service: .appleMusic, reason: reason)
            await session.next()
            guard case .error = session.connectionState else {
                return XCTFail("Expected \(reason) to show, got \(session.connectionState)")
            }
            XCTAssertNil(session.passingErrorRecoveryTask, "\(reason) must stay on screen")
            try await Task.sleep(for: .milliseconds(60))
            guard case .error = session.connectionState else {
                return XCTFail("\(reason) went away: \(session.connectionState)")
            }
        }
    }

    // MARK: - Measured MusicKit lag

    /// Replays the lag measured on a Mac mini M4 (macOS 27, 2026-11-06): how long
    /// `ApplicationMusicPlayer` kept reporting the old state after each command returned.
    /// Pause up to 333 ms, play 297 ms, next 305 ms (old item at position 0), previous
    /// 189 ms. The session reads once right after a command and then every second, so
    /// its 2-read settle window has to hide the first, stale read and apply the second.
    func testSettleWindowCoversMeasuredPauseAndResumeLag() async throws {
        let (player, session) = try await Self.playingSession()

        await session.togglePlayPause()
        XCTAssertEqual(player.commands.last, "pause")
        try await Self.read(session, player, at: 0.07)
        XCTAssertTrue(Self.isPaused(session), "a read 70 ms after pause still says playing and must not undo it")
        try await Self.read(session, player, at: 1.07)
        XCTAssertTrue(Self.isPaused(session))
        XCTAssertEqual(session.localMutationSettleTicksRemaining, 0, "two reads end the window")
        try await Self.read(session, player, at: 2.07)
        XCTAssertTrue(Self.isPaused(session))

        await session.togglePlayPause()
        XCTAssertEqual(player.commands.last, "resume")
        try await Self.read(session, player, at: 0.07)
        XCTAssertTrue(Self.isPlaying(session), "a read 70 ms after play still says paused and must not undo it")
        try await Self.read(session, player, at: 1.07)
        XCTAssertTrue(Self.isPlaying(session))
        XCTAssertEqual(session.localMutationSettleTicksRemaining, 0)
    }

    /// Without the skip fence the first read after "next" put the old song back on screen
    /// at 0:00 for a second (seen on the real player). It must keep the old position until
    /// MusicKit reports the next song.
    func testStaleReadAfterNextDoesNotJumpTheOldSongToZero() async throws {
        let (player, session) = try await Self.playingSession()
        try await Self.read(session, player, at: 40)
        let before = try XCTUnwrap(session.currentNowPlaying)
        XCTAssertEqual(before.uri, Self.uris[0])

        await session.next()
        XCTAssertEqual(player.commands.last, "next")
        try await Self.read(session, player, at: 0.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
        XCTAssertGreaterThan(session.currentNowPlaying?.positionMilliseconds ?? 0, 30_000, "the stale position-0 read was applied")

        try await Self.read(session, player, at: 1.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[1])
        XCTAssertTrue(Self.isPlaying(session))
    }

    func testStaleReadAfterPreviousIsIgnoredToo() async throws {
        let (player, session) = try await Self.playingSession(startIndex: 2)
        try await Self.read(session, player, at: 10)

        await session.previous()
        try await Self.read(session, player, at: 0.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[2])
        try await Self.read(session, player, at: 1.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[1])
    }

    /// Previous on the first song restarts it: the same item comes back, and once the settle
    /// window is over it is shown again.
    func testRestartOfTheSameSongIsShownAfterTheWindow() async throws {
        let (player, session) = try await Self.playingSession()
        try await Self.read(session, player, at: 20)
        await session.previous()
        try await Self.read(session, player, at: 0.07)
        try await Self.read(session, player, at: 1.07)
        try await Self.read(session, player, at: 1.0)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
        XCTAssertLessThan(session.currentNowPlaying?.positionMilliseconds ?? .max, 5_000)
    }

    // MARK: - Errors name the service

    func testSpotifyErrorsKeepTheirMessages() {
        let premium = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.forbidden(message: nil, details: nil))
        XCTAssertEqual(premium.title, SpotiglassL10n.string("error.playback.premium.title"))
        let expired = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.unauthorized)
        XCTAssertEqual(expired.recoveryAction, .reauthenticate)
        let failed = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.server(statusCode: 502, message: nil, details: nil))
        // The sentence, not the error's debug text (#470).
        XCTAssertEqual(failed.message, SpotiglassL10n.string("error.spotify.serverProblem"))
    }

    func testAppleMusicErrorsNameAppleMusic() {
        let subscription = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .subscriptionRequired(message: nil))
        )
        XCTAssertEqual(subscription.title, SpotiglassL10n.string("error.playback.appleMusic.subscription.title"))
        XCTAssertNil(subscription.recoveryAction)
        let permission = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .missingPermission)
        )
        XCTAssertEqual(permission.message, SpotiglassL10n.string("error.playback.appleMusic.permission.message"))
        XCTAssertNotEqual(permission.recoveryAction, .reauthenticate, "Apple Music has no Spotify sign-in to repeat")
        let queue = QueueViewModel.displayError(for: MusicPlaybackError(service: .appleMusic, reason: .missingPermission))
        XCTAssertEqual(queue?.message, SpotiglassL10n.string("error.playback.appleMusic.permission.message"))
    }

    // MARK: - Lyrics

    func testLyricsKeyCoversAppleMusicSongsAndKeepsSpotifyKeys() {
        XCTAssertEqual(Self.nowPlaying(uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC").lyricsTrackKey, "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(Self.nowPlaying(uri: "applemusic:song:1440857781").lyricsTrackKey, "applemusic-song-1440857781")
        XCTAssertEqual(Self.nowPlaying(uri: "applemusic:song:i.B0VNYlBtxzX7aak").lyricsTrackKey, "applemusic-song-i-B0VNYlBtxzX7aak")
        XCTAssertNil(Self.nowPlaying(uri: "applemusic:music-video:1").lyricsTrackKey)
        XCTAssertNil(Self.nowPlaying(uri: "spotify:episode:1").lyricsTrackKey)
    }

    func testAppleMusicTracksGetLyrics() async {
        let track = Self.nowPlaying(uri: "applemusic:song:1440857781")
        XCTAssertEqual(PlaybackConnectionState.playing(track).currentLyricTrack, track)

        let queued = QueueItem.from(playback: track)
        XCTAssertEqual(queued.playbackNowPlayingForLyricsPrefetch()?.uri, track.uri)

        var fetched: [String] = []
        let lyrics = ImmersiveLyricsViewModel { track in
            fetched.append(track.name)
            return .instrumental
        }
        await lyrics.load(track: track)
        XCTAssertEqual(fetched, ["Can't Hold Us"])
        XCTAssertEqual(lyrics.phase, .ready(.instrumental))
    }

    /// The transport bar's hints and connecting text name Apple Music in Apple Music mode, and
    /// Spotify keeps its own text.
    func testTransportTextNamesTheSelectedService() {
        let pairs = [
            ("playback.controls.previous.hint", "playback.controls.previous.appleMusic.hint"),
            ("playback.controls.playPause.hint", "playback.controls.playPause.appleMusic.hint"),
            ("playback.controls.next.hint", "playback.controls.next.appleMusic.hint"),
            ("playback.controls.state.connecting.title", "playback.controls.state.connecting.title.appleMusic"),
            ("playback.controls.state.connecting.subtitle", "playback.controls.state.connecting.subtitle.appleMusic"),
            ("playback.fallbackName", "playback.fallbackName.appleMusic"),
            ("playback.controls.device.hint", "playback.controls.device.appleMusic.hint"),
            ("queue.shuffle.hint", "queue.shuffle.appleMusic.hint"),
        ]
        for (spotifyKey, appleMusicKey) in pairs {
            let spotify = PlaybackControlsView.serviceString(spotifyKey, appleMusic: appleMusicKey, service: .spotify)
            let appleMusic = PlaybackControlsView.serviceString(spotifyKey, appleMusic: appleMusicKey, service: .appleMusic)
            XCTAssertEqual(spotify, SpotiglassL10n.string(spotifyKey), spotifyKey)
            XCTAssertTrue(spotify.contains("Spotify"), "\(spotifyKey): \(spotify)")
            XCTAssertFalse(appleMusic.contains("Spotify"), "\(appleMusicKey): \(appleMusic)")
            XCTAssertTrue(appleMusic.contains("Apple Music"), "\(appleMusicKey): \(appleMusic)")
        }
    }

    // MARK: - Playable registry

    func testMappingASongRemembersItForPlayback() throws {
        let song = try AppleMusicFixtures.song(id: "-7726707972698117572", title: "Can't Hold Us")
        let track = AppleMusicItemMapping.track(song)
        XCTAssertEqual(track.uri, "applemusic:song:-7726707972698117572")
        XCTAssertEqual(AppleMusicPlayableRegistry.shared.song(for: track.uri)?.id, song.id)
    }

    /// The songs of the list viewed first (Liked Songs) must not be evicted first just because
    /// they were registered first: viewing the list again makes them recent, and only songs
    /// nobody touched in a long time go (#400).
    func testRegistryEvictsTheLeastRecentlyUsedSongs() throws {
        let registry = AppleMusicPlayableRegistry(capacity: 4)
        let songs = try (1...6).map { try AppleMusicFixtures.song(id: "\($0)", title: "Song \($0)") }
        func uri(_ n: Int) -> String { "applemusic:song:\(n)" }
        for n in 1...4 { registry.register(songs[n - 1], for: uri(n)) }
        // Song 1 is mapped again (its list was reopened) and song 2 is looked up for playback.
        registry.register(songs[0], for: uri(1))
        XCTAssertEqual(registry.song(for: uri(2))?.id, songs[1].id)
        // A fifth song goes past the capacity and one batch is evicted down to 90 % (3 songs):
        // the least recently used ones (3, 4) go, not the first ones registered.
        registry.register(songs[4], for: uri(5))
        for dropped in [3, 4] { XCTAssertNil(registry.song(for: uri(dropped)), "song \(dropped)") }
        for kept in [1, 2, 5] { XCTAssertEqual(registry.song(for: uri(kept))?.id, songs[kept - 1].id, "song \(kept)") }
        // Registering a URI again doesn't count as a new entry.
        registry.register(songs[4], for: uri(5))
        registry.register(songs[0], for: uri(1))
        for kept in [1, 2, 5] { XCTAssertNotNil(registry.song(for: uri(kept)), "song \(kept)") }
    }

    // MARK: - Header play

    /// Right after launch the Apple Music player has no queue and reports nothing, so the
    /// session doesn't know its transport yet. The header's Shuffle must still shuffle.
    func testHeaderShuffleOnAFreshPlayerTurnsShuffleOn() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        XCTAssertFalse(session.isTransportStateKnown)

        await DetailHeaderPlayback.shuffleAndPlay(target: .tracks(uris: Self.uris, playlistID: "p"), using: session)

        XCTAssertTrue(player.commands.contains("play"))
        let state = try await provider.fetchPlaybackState()
        XCTAssertEqual(state?.transport.shuffle, true)
    }

    /// Access turned off while the app runs: connecting fails with Apple Music's own
    /// permission text, not the raw diagnostic, and offers no Reconnect that can't help.
    func testAFailedAppleMusicConnectSaysToTurnAccessBackOn() async {
        let player = ScriptedAppleMusicPlayer()
        player.authorized = false
        let provider = AppleMusicPlaybackProvider(player: player)
        do {
            try await provider.connectPlayer(generation: .initial)
            XCTFail("Expected a permission error")
        } catch {
            let shown = PlaybackSessionViewModel.playbackHostConnectionFailedError(for: error)
            XCTAssertEqual(shown.message, SpotiglassL10n.string("error.playback.appleMusic.permission.message"))
            XCTAssertNil(shown.recoveryAction)
        }
        let spotify = PlaybackSessionViewModel.playbackHostConnectionFailedError(for: URLError(.timedOut))
        XCTAssertEqual(spotify.title, SpotiglassL10n.string("error.playback.couldNotStart.title"))
        XCTAssertEqual(spotify.recoveryAction, .reconnect)
    }

    /// The header's Shuffle starts at a random song. MusicKit only shuffles what comes after
    /// the first song, so that song moves to the front and every other song still plays.
    func testShuffleStartKeepsEverySongAhead() {
        let songs = Array(1...10)
        let order = MusicKitApplicationPlayer.movingToFront(songs, index: 9)
        XCTAssertEqual(order.first, 10)
        XCTAssertEqual(Array(order.dropFirst()), Array(1...9), "songs 1-9 still come after it")
        XCTAssertEqual(MusicKitApplicationPlayer.movingToFront(songs, index: 0), songs)
        XCTAssertEqual(MusicKitApplicationPlayer.movingToFront(songs, index: 99), songs)
    }

    func testDetailHeaderPlaysTheAppleMusicContext() {
        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(albumDisplayName: "Album", artistsDisplay: "A", totalTrackCount: 1, artworkURL: nil, albumID: "1440857781"),
            tracks: []
        )
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .appleMusic), .context(uri: "applemusic:album:1440857781", playlistID: "1440857781"))
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .spotify), .context(uri: "spotify:album:1440857781", playlistID: "1440857781"))
    }

    // MARK: - Fixtures

    static let uris = (1...6).map { "applemusic:song:\($0)" }

    private static func uri(_ item: MusicPlaybackItem) -> String? {
        if case let .track(track) = item { return track.uri }
        return nil
    }

    private static func nowPlaying(uri: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Can't Hold Us",
            artists: ["Macklemore & Ryan Lewis"],
            albumName: "The Heist",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 258_000,
            positionMilliseconds: 0,
            uri: uri
        )
    }

    private static func playingSession(
        startIndex: Int = 0,
        passingErrorRecoveryDelay: Duration = .seconds(5)
    ) async throws -> (ScriptedAppleMusicPlayer, PlaybackSessionViewModel) {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider, passingErrorRecoveryDelay: passingErrorRecoveryDelay)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        try await provider.play(.items(uris: uris, startURI: uris[startIndex]), deviceID: "x")
        player.advance(by: 1)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.currentNowPlaying?.uri, uris[startIndex])
        return (player, session)
    }

    /// Moves the scripted player's clock forward and reads, like the session's poll does.
    private static func read(_ session: PlaybackSessionViewModel, _ player: ScriptedAppleMusicPlayer, at seconds: Double) async throws {
        player.advance(by: seconds)
        await session.syncTransportFromSpotify()
    }

    private static func isPaused(_ session: PlaybackSessionViewModel) -> Bool {
        if case .paused = session.connectionState { return true }
        return false
    }

    private static func isPlaying(_ session: PlaybackSessionViewModel) -> Bool {
        if case .playing = session.connectionState { return true }
        return false
    }
}

/// MusicKit's `ApplicationMusicPlayer` with the measured lag: a command takes effect only
/// after `lag` seconds of scripted time; until then reads still show the old state (and a
/// skip already reports position 0 for the old item, as the real player does).
@MainActor
final class ScriptedAppleMusicPlayer: AppleMusicPlayerControlling {
    static let lag: [String: Double] = ["pause": 0.333, "resume": 0.297, "next": 0.305, "previous": 0.189, "stop": 0.074]

    var authorized = true
    var failure: Error?
    /// A skip MusicKit refuses; the song that was playing keeps playing.
    var skipFailure: MusicPlaybackError?
    private(set) var commands: [String] = []
    /// While true, play and enqueue wait in their lookup (like a slow MusicKit request) until
    /// ``releaseLookups()``. ``waitingLookups`` names who waits.
    var holdLookups = false
    /// While true, play waits after it set its queue (like MusicKit's own `play()` finishing)
    /// until ``releaseLookups()``; it waits as "started <uri>".
    var holdAfterQueueSet = false
    private var lookupWaiters: [(name: String, resume: CheckedContinuation<Void, Never>)] = []
    var waitingLookups: [String] { lookupWaiters.map(\.name) }

    func releaseLookups() {
        let waiting = lookupWaiters
        lookupWaiters.removeAll()
        waiting.forEach { $0.resume.resume() }
    }

    private func lookup(_ name: String) async {
        guard holdLookups else { return }
        await withCheckedContinuation { lookupWaiters.append((name, $0)) }
    }

    private var now = 0.0
    private var queue: [String] = []
    private var index = 0
    private var playing = false
    private var positionBase = 0.0
    private var positionAnchor = 0.0
    private var shuffle = false
    private var repeatMode: MusicRepeatMode = .off
    /// The live player's queue rules, on this queue.
    private var book = AppleMusicQueueBook()
    private var pending: [(at: Double, apply: () -> Void)] = []

    func advance(by seconds: Double) {
        now += seconds
        let due = pending.filter { $0.at <= now }
        pending.removeAll { $0.at <= now }
        due.forEach { $0.apply() }
    }

    private func position() -> Double {
        playing ? positionBase + (now - positionAnchor) : positionBase
    }

    private func later(_ command: String, _ apply: @escaping () -> Void) {
        commands.append(command)
        pending.append((now + (Self.lag[command] ?? 0), apply))
    }

    func isAuthorized() -> Bool { authorized }

    func play(_ request: AppleMusicQueueRequest, isCurrent: @escaping @MainActor () -> Bool) async throws {
        if let failure = failure as? MusicPlaybackError { throw failure }
        if let failure { throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "\(failure)") }
        guard case let .items(uris, start) = request else { throw MusicPlaybackError(service: .appleMusic, reason: .notFound) }
        await lookup("play \(start ?? uris.first ?? "")")
        // The live player's contract: a play overtaken during its lookup leaves the queue alone.
        guard isCurrent() else { throw CancellationError() }
        commands.append("play")
        // Like the live player: added songs not played yet go right after the new first song.
        let carried = (book.addedAhead(of: queue.indices.contains(index) ? index : nil) ?? 0..<0)
            .filter(queue.indices.contains)
            .map { queue[$0] }
        let startIndex = start.flatMap { uris.firstIndex(of: $0) } ?? 0
        var newQueue = uris
        newQueue.insert(contentsOf: carried, at: startIndex + 1)
        queue = newQueue
        index = startIndex
        playing = true
        positionBase = 0
        positionAnchor = now
        book.replace(
            with: newQueue.map { AppleMusicQueueBook.Row(uri: $0, title: $0) },
            carryingAdded: carried.count,
            after: startIndex
        )
        if holdAfterQueueSet {
            await withCheckedContinuation { lookupWaiters.append(("started \(newQueue[startIndex])", $0)) }
        }
    }

    func pause() {
        later("pause") { [self] in positionBase = position(); playing = false }
    }

    func resume() async throws {
        later("resume") { [self] in positionAnchor = now; playing = true }
    }

    /// Like the live player: the queue stays, the songs added to it are forgotten.
    func stop() {
        book = AppleMusicQueueBook()
        later("stop") { [self] in positionBase = position(); playing = false }
    }

    func seek(toMilliseconds milliseconds: Int) {
        commands.append("seek")
        positionBase = Double(milliseconds) / 1000
        positionAnchor = now
    }

    func skipToNext() async throws {
        if let skipFailure { throw skipFailure }
        positionBase = 0
        positionAnchor = now
        later("next") { [self] in index = min(index + 1, queue.count - 1); positionBase = 0; positionAnchor = now }
    }

    func skipToPrevious() async throws {
        let restart = index == 0
        positionBase = 0
        positionAnchor = now
        later("previous") { [self] in if !restart { index -= 1 }; positionBase = 0; positionAnchor = now }
    }

    func setShuffle(_ enabled: Bool) {
        shuffle = enabled
        book.forgetPositions()
    }
    func setRepeat(_ mode: MusicRepeatMode) { repeatMode = mode }

    func enqueue(uri: String, isCurrent: @escaping @MainActor () -> Bool) async throws {
        await lookup("enqueue \(uri)")
        // The live player's contract: an add from a session that ended leaves the queue alone.
        guard isCurrent() else { throw CancellationError() }
        commands.append("enqueue \(uri)")
        let current = queue.indices.contains(index) ? index : nil
        let plan = book.planAdd(AppleMusicQueueBook.Row(uri: uri, title: uri), currentIndex: current, entryCount: queue.count)
        queue.insert(uri, at: min(plan.index ?? current.map { $0 + 1 } ?? queue.count, queue.count))
        book.finishAdd(plan)
    }

    func readState() -> AppleMusicPlayerState {
        guard queue.indices.contains(index) else {
            return AppleMusicPlayerState(status: .stopped, current: nil, positionMilliseconds: 0, shuffle: shuffle, repeatMode: repeatMode)
        }
        return AppleMusicPlayerState(
            status: playing ? .playing : .paused,
            current: Self.track(queue[index]),
            positionMilliseconds: Int(position() * 1000),
            shuffle: shuffle,
            repeatMode: repeatMode
        )
    }

    func readUpcoming() -> [MusicTrack] {
        guard queue.indices.contains(index) else { return [] }
        return queue[(index + 1)...].map(Self.track)
    }

    private static func track(_ uri: String) -> MusicTrack {
        MusicTrack(
            id: uri,
            name: uri,
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 240_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: uri
        )
    }
}

/// MusicKit's player as measured for #476: a new queue is taken at once; a queue that names its
/// start can be refused ("Prepare queue failed with unexpected start item"), and a song it won't
/// play is refused ("Failed to prepare to play"). Either way the refused queue stays current,
/// paused at 0:00.
@MainActor
final class RefusingQueueStarter: AppleMusicQueueStarting {
    let refusedIDs: Set<String>
    var refusesNamedStart: Bool
    private(set) var entries: [MusicPlayer.Queue.Entry] = []
    private(set) var currentEntry: MusicPlayer.Queue.Entry?
    private(set) var isPlaying = false
    private(set) var commands: [String] = []
    /// The start each queue named, by title (nil: none named).
    private(set) var namedStarts: [String?] = []
    private var startIsNamed = false
    var playbackTime: TimeInterval = 0

    init(refusing ids: Set<String> = [], refusesNamedStart: Bool = false) {
        refusedIDs = ids
        self.refusesNamedStart = refusesNamedStart
    }

    func setQueue(_ entries: [MusicPlayer.Queue.Entry], startingAt entry: MusicPlayer.Queue.Entry?) {
        commands.append("queue")
        namedStarts.append(entry?.title)
        self.entries = entries
        currentEntry = entry ?? entries.first
        startIsNamed = entry != nil
        isPlaying = false
        playbackTime = 0
    }

    func play() async throws {
        commands.append("play")
        try await whileMusicKitWorks()
        isPlaying = currentEntry != nil
    }

    func prepareToPlay() async throws {
        commands.append("prepare")
        try await whileMusicKitWorks()
    }

    /// Holds every play and prepare until ``releasePlay()``, like MusicKit working on it, so a
    /// test can press again meanwhile.
    var holdsPlays = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Lets the play held longest go on.
    func releasePlay() {
        guard !held.isEmpty else { return XCTFail("no play is held") }
        held.removeFirst().resume()
    }

    /// Waits until `count` plays are held.
    func waitForHeldPlays(_ count: Int) async {
        for _ in 0..<10_000 where held.count < count {
            await Task.yield()
        }
        XCTAssertEqual(held.count, count, "plays held")
    }

    /// MusicKit decides on the queue it was handed; what happens while it works comes after.
    private func whileMusicKitWorks() async throws {
        let refusal = Result { try refuseIfNeeded() }
        if holdsPlays {
            await withCheckedContinuation { held.append($0) }
        }
        try refusal.get()
    }

    func pause() {
        commands.append("pause")
        isPlaying = false
    }

    func stop() {
        commands.append("stop")
        isPlaying = false
    }

    private func refuseIfNeeded() throws {
        if refusesNamedStart, startIsNamed {
            isPlaying = false
            throw NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6, userInfo: [NSDebugDescriptionErrorKey: "Prepare queue failed with unexpected start item"])
        }
        guard case let .song(song) = currentEntry?.item, refusedIDs.contains(song.id.rawValue) else { return }
        isPlaying = false
        playbackTime = 0
        throw NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6, userInfo: [NSDebugDescriptionErrorKey: "Failed to prepare to play"])
    }
}
