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
        XCTAssertEqual(
            failed.message,
            String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), String(describing: SpotifyAPIError.server(statusCode: 502, message: nil, details: nil)))
        )
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
            ("playback.controls.reconnect.hint", "playback.controls.reconnect.appleMusic.hint"),
            ("playback.controls.reconnect.sdk.hint", "playback.controls.reconnect.appleMusic.hint"),
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

    func testRegistryIsBounded() throws {
        let registry = AppleMusicPlayableRegistry(capacity: 4)
        let songs = try (1...5).map { try AppleMusicFixtures.song(id: "\($0)", title: "Song \($0)") }
        func uri(_ n: Int) -> String { "applemusic:song:\(n)" }
        for (index, song) in songs.enumerated() { registry.register(song, for: uri(index + 1)) }
        // Past the capacity the oldest half is dropped: 5 > 4 keeps the newest 2.
        for dropped in 1...3 { XCTAssertNil(registry.song(for: uri(dropped)), "song \(dropped)") }
        XCTAssertEqual(registry.song(for: uri(4))?.id, songs[3].id)
        XCTAssertEqual(registry.song(for: uri(5))?.id, songs[4].id)
        // Registering a URI again doesn't count as a new entry: two more re-registrations
        // and one new song (3 entries) stay under the capacity, so nothing is dropped.
        registry.register(songs[4], for: uri(5))
        registry.register(songs[4], for: uri(5))
        registry.register(songs[0], for: uri(1))
        XCTAssertEqual(registry.song(for: uri(4))?.id, songs[3].id)
        XCTAssertEqual(registry.song(for: uri(1))?.id, songs[0].id)
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
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .appleMusic), .context(uri: "applemusic:album:1440857781"))
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .spotify), .context(uri: "spotify:album:1440857781"))
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

    private static func playingSession(startIndex: Int = 0) async throws -> (ScriptedAppleMusicPlayer, PlaybackSessionViewModel) {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
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
    private(set) var commands: [String] = []
    /// While true, play and enqueue wait in their lookup (like a slow MusicKit request) until
    /// ``releaseLookups()``. ``waitingLookups`` names who waits.
    var holdLookups = false
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
    }

    func pause() {
        later("pause") { [self] in positionBase = position(); playing = false }
    }

    func resume() async throws {
        later("resume") { [self] in positionAnchor = now; playing = true }
    }

    func stop() {
        later("stop") { [self] in positionBase = position(); playing = false }
    }

    func seek(toMilliseconds milliseconds: Int) {
        commands.append("seek")
        positionBase = Double(milliseconds) / 1000
        positionAnchor = now
    }

    func skipToNext() async throws {
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

    func enqueue(uri: String) async throws {
        await lookup("enqueue \(uri)")
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
