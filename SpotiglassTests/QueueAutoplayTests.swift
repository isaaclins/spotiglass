import XCTest
@testable import Spotiglass

/// Autoplay (#613) on the Apple Music provider, with the scripted MusicKit player and sample
/// songs: the sessions from the issue (a 4-song seed, a long session, skipping, adding songs by
/// hand while it is on, turning it off), then the ranking and the catalog scoring on their own.
@MainActor
final class QueueAutoplayTests: XCTestCase {
    private let deviceID = AppleMusicPlaybackProvider.deviceID
    private let seeds = (1...4).map { "applemusic:song:seed-\($0)" }

    private struct Harness {
        let player: ScriptedAppleMusicPlayer
        let provider: AppleMusicPlaybackProvider
        let source: SampleAutoplaySource
        let autoplay: QueueAutoplay
        let adapter: ProviderQueueAutoplayPlayer
    }

    private func makeHarness(fillTarget: Int = 8) -> Harness {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let source = SampleAutoplaySource()
        let autoplay = QueueAutoplay(
            source: source,
            flag: StoredFlag(key: "test.autoplay", defaultValue: false, defaults: nil),
            fillTarget: fillTarget
        )
        let adapter = ProviderQueueAutoplayPlayer(provider: provider) { AppleMusicPlaybackProvider.deviceID }
        autoplay.player = adapter
        return Harness(player: player, provider: provider, source: source, autoplay: autoplay, adapter: adapter)
    }

    /// What the session does on each new song: read the player and tell Autoplay.
    private func notePlaying(_ h: Harness) async throws {
        let state = h.player.readState()
        h.autoplay.nowPlayingChanged(state.current.map { QueueAutoplaySeed(track: $0) })
        await h.autoplay.settle()
    }

    private func next(_ h: Harness) async throws {
        try await h.provider.skipToNext(deviceID: deviceID)
        h.player.advance(by: 1)
        try await notePlaying(h)
    }

    private func upcoming(_ h: Harness) async throws -> [String] {
        try await h.provider.fetchQueue().queue.compactMap { item in
            if case let .track(track) = item { return track.uri }
            return nil
        }
    }

    private func current(_ h: Harness) -> String? {
        h.player.readState().current?.uri
    }

    // MARK: - Sessions

    /// Four seeded songs, Autoplay on: the queue fills up after them with new songs, never one
    /// of the seeds, and the seeds keep their order.
    func testFourSongSeedFillsTheQueueAfterTheSeededSongs() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)

        h.autoplay.setEnabled(true)
        await h.autoplay.settle()

        let queue = try await upcoming(h)
        XCTAssertEqual(queue.count, 8)
        XCTAssertEqual(Array(queue.prefix(3)), Array(seeds.dropFirst()), "the seeded songs stay first, in order")
        XCTAssertTrue(queue.dropFirst(3).allSatisfy { $0.hasPrefix("applemusic:song:new-") })
        XCTAssertEqual(h.autoplay.status, .on)
        // The suggestions were asked from the seeded songs.
        let asked = try XCTUnwrap(h.source.requests.last)
        XCTAssertEqual(Set(asked.compactMap(\.uri)), Set(seeds))
    }

    /// A long session: 40 songs finish one after another. The queue never runs dry, each new
    /// song adds exactly one, and no song is ever added twice or after it was heard.
    func testLongSessionNeverRunsDryAndNeverRepeats() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()

        var heard: [String] = [try XCTUnwrap(current(h))]
        for _ in 0..<40 {
            let before = try await upcoming(h).count
            try await next(h)
            let now = try XCTUnwrap(current(h))
            XCTAssertFalse(heard.contains(now), "\(now) played twice")
            heard.append(now)
            let after = try await upcoming(h)
            XCTAssertEqual(after.count, max(before, 8), "one song finished, one was added")
            XCTAssertTrue(Set(after).isDisjoint(with: heard), "a heard song came back")
            XCTAssertEqual(Set(after).count, after.count, "a song is queued twice")
        }
        let appended = h.player.commands.filter { $0.hasPrefix("append ") }.map { String($0.dropFirst("append ".count)) }
        XCTAssertEqual(Set(appended).count, appended.count)
        XCTAssertEqual(appended.count, 5 + 40)
    }

    /// Skipping five songs in a row adds one song per new song, and none that was skipped.
    func testSkippingAddsOnePerNewSongWithoutRepeats() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        let appendsBefore = h.player.commands.filter { $0.hasPrefix("append ") }.count

        var skipped: [String] = []
        for _ in 0..<5 {
            skipped.append(try XCTUnwrap(current(h)))
            try await next(h)
        }
        let appendsAfter = h.player.commands.filter { $0.hasPrefix("append ") }.count
        XCTAssertEqual(appendsAfter - appendsBefore, 5)
        let queue1 = try await upcoming(h)
        XCTAssertTrue(Set(queue1).isDisjoint(with: skipped))
        let queue2 = try await upcoming(h)
        XCTAssertEqual(queue2.count, 8)
    }

    /// Going back to a song heard before adds nothing: only new songs move the queue on.
    func testGoingBackAddsNothing() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        try await next(h)
        let appends = h.player.commands.filter { $0.hasPrefix("append ") }.count

        try await h.provider.skipToPrevious(deviceID: deviceID)
        h.player.advance(by: 1)
        try await notePlaying(h)

        XCTAssertEqual(current(h), seeds[0])
        XCTAssertEqual(h.player.commands.filter { $0.hasPrefix("append ") }.count, appends)
    }

    /// Songs added by hand while Autoplay is on play where Add to Queue put them, before the
    /// Autoplay songs, and steer what comes next.
    func testSongsAddedByHandStayWhereTheyWentAndSteer() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        let autoplaySongs = try await upcoming(h).filter { $0.hasPrefix("applemusic:song:new-") }

        let mine = ["applemusic:song:mine-1", "applemusic:song:mine-2"]
        for uri in mine {
            try await h.provider.enqueue(uri: uri, deviceID: deviceID)
        }
        let queue = try await upcoming(h)
        XCTAssertEqual(Array(queue.prefix(2)), mine, "Add to Queue puts them right after the current song")
        XCTAssertEqual(Array(queue.suffix(autoplaySongs.count)), autoplaySongs, "Autoplay's songs stay after them")

        try await next(h)
        XCTAssertEqual(current(h), mine[0])
        let queue3 = try await upcoming(h)
        XCTAssertEqual(queue3.first, mine[1], "a hand-added song isn't moved")
        let queue4 = try await upcoming(h)
        XCTAssertTrue(queue4.last?.hasPrefix("applemusic:song:new-") == true, "the new song went at the end")

        // The hand-added songs count fully in the seeds; Autoplay's own songs count half.
        let seedsAsked = try XCTUnwrap(h.source.requests.last)
        let weightByURI = Dictionary(seedsAsked.compactMap { seed in seed.uri.map { ($0, seed.weight) } }, uniquingKeysWith: max)
        let mineWeight = try XCTUnwrap(weightByURI[mine[1]])
        let autoplayWeight = try XCTUnwrap(weightByURI[autoplaySongs[0]])
        XCTAssertGreaterThan(mineWeight, autoplayWeight)
    }

    /// Turning Autoplay off stops adding; what is queued stays.
    func testTurningOffStopsAddingAndKeepsTheQueue() async throws {
        let h = makeHarness()
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        let queued = try await upcoming(h)

        h.autoplay.setEnabled(false)
        XCTAssertEqual(h.autoplay.status, .off)
        try await next(h)
        try await next(h)

        let queue5 = try await upcoming(h)
        XCTAssertEqual(queue5, Array(queued.dropFirst(2)))
    }

    /// Turned on before anything plays, Autoplay waits for the first song instead of starting a
    /// queue of its own.
    func testOnBeforeAnythingPlaysWaitsForTheFirstSong() async throws {
        let h = makeHarness()
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        XCTAssertTrue(h.player.commands.filter { $0.hasPrefix("append ") }.isEmpty)
        XCTAssertTrue(h.source.requests.isEmpty)

        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        let queue6 = try await upcoming(h)
        XCTAssertEqual(queue6.count, 8)
    }

    /// A song the player refuses (not in the storefront) is skipped for the next suggestion.
    func testARefusedSongIsReplacedByTheNextSuggestion() async throws {
        let h = makeHarness()
        h.player.refusedURIs = ["applemusic:song:new-1"]
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()

        let queue = try await upcoming(h)
        XCTAssertEqual(queue.count, 8)
        XCTAssertFalse(queue.contains("applemusic:song:new-1"))
    }

    /// With nothing new left in this style, Autoplay says so instead of repeating songs.
    func testRunningOutOfSuggestionsSaysSo() async throws {
        let h = makeHarness()
        h.source.poolSize = 2
        try await h.provider.play(.items(uris: seeds, startURI: nil), deviceID: deviceID)
        try await notePlaying(h)
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        let queue7 = try await upcoming(h)
        XCTAssertEqual(queue7.count, 5)
        XCTAssertEqual(h.autoplay.status, .noMatches)

        try await next(h)
        XCTAssertEqual(h.autoplay.status, .noMatches)
        let queue8 = try await upcoming(h)
        XCTAssertEqual(queue8.count, 4, "nothing is added twice")
    }

    // MARK: - Queue book

    /// Autoplay appends after everything; a later Add to Queue still goes right after the
    /// songs added before it, ahead of Autoplay's.
    func testAppendGoesToTheEndAndAddToQueueStaysAheadOfIt() {
        var book = AppleMusicQueueBook()
        book.replace(with: ["a", "b", "c"].map { AppleMusicQueueBook.Row(uri: $0, title: $0) })
        let added = book.planAdd(.init(uri: "mine", title: "mine"), currentIndex: 0, entryCount: 3)
        XCTAssertEqual(added.index, 1)
        book.finishAdd(added)
        let appended = book.planAppend(.init(uri: "auto", title: "auto"), currentIndex: 0, entryCount: 4)
        XCTAssertEqual(appended.index, 4)
        book.finishAdd(appended)
        let second = book.planAdd(.init(uri: "mine2", title: "mine2"), currentIndex: 0, entryCount: 5)
        XCTAssertEqual(second.index, 2)
        book.finishAdd(second)
        XCTAssertEqual(book.rows.map(\.uri), ["a", "mine", "mine2", "b", "c", "auto"])
    }

    // MARK: - Ranking

    func testRankingSkipsHeardSongsUnderAnotherIDAndSpreadsArtists() {
        let heard = Self.track("i.LIBRARY", title: "Midnight City", artist: "M83")
        let candidates = [
            QueueAutoplayCandidate(track: Self.track("1001", title: "Midnight City (Remastered)", artist: "M83"), score: 9),
            QueueAutoplayCandidate(track: Self.track("1002", title: "Wait", artist: "M83"), score: 8),
            QueueAutoplayCandidate(track: Self.track("1003", title: "Outro", artist: "M83"), score: 7),
            QueueAutoplayCandidate(track: Self.track("2001", title: "Kids", artist: "MGMT"), score: 6),
            QueueAutoplayCandidate(track: Self.track("2001", title: "Kids", artist: "MGMT"), score: 5),
        ]
        let picks = QueueAutoplayRanking.pick(
            candidates,
            count: 3,
            excluded: QueueAutoplayIdentity.keys(heard),
            lastArtistKey: "m83"
        )
        XCTAssertEqual(picks.map(\.id), ["2001", "1002", "1003"])
    }

    func testCatalogScoringPrefersSimilarArtistsOverTheSameArtistsHits() {
        let profiles: [String: AppleMusicAutoplaySource.ArtistProfile] = [
            "1": .init(similarArtistIDs: ["2", "3"], topSongs: [Self.track("own", title: "Own Hit", artist: "One")]),
        ]
        let top = [
            "2": [Self.track("sim2", title: "Similar Two", artist: "Two")],
            "3": [Self.track("sim3", title: "Similar Three", artist: "Three")],
        ]
        let scored = AppleMusicAutoplaySource.score(seedArtists: [("1", 1)], profiles: profiles, topSongsByArtistID: top)
        let ranked = QueueAutoplayRanking.pick(scored, count: 3, excluded: [], lastArtistKey: nil)
        XCTAssertEqual(ranked.map(\.id), ["sim2", "sim3", "own"])
    }

    func testArtistWeightsLeanOnTheRecentArtists() {
        let weights = AppleMusicAutoplaySource.artistWeights([
            QueueAutoplaySeed(uri: "a", title: "A", artists: ["Björk"], artistIDs: ["r.lib"], weight: 0.5),
            QueueAutoplaySeed(uri: "b", title: "B", artists: ["Bjork"], artistIDs: ["123"], weight: 0.5),
            QueueAutoplaySeed(uri: "c", title: "C", artists: ["Air"], weight: 0.8),
        ])
        XCTAssertEqual(weights.map(\.name), ["Björk", "Air"])
        XCTAssertEqual(weights.first?.weight, 1)
        XCTAssertEqual(weights.first?.idHint, "123", "a library ID isn't a catalog ID; the catalog one is used")
    }

    static func track(_ id: String, title: String, artist: String) -> MusicTrack {
        MusicTrack(
            id: id,
            name: title,
            artists: [artist],
            albumArtworkURL: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "applemusic:song:\(id)"
        )
    }
}

/// Suggests sample songs `new-1`, `new-2`, … best first, spread over five artists, plus the
/// seeds themselves (which Autoplay must never add again). Records every request.
@MainActor
final class SampleAutoplaySource: QueueAutoplaySource {
    var poolSize = 200
    private(set) var requests: [[QueueAutoplaySeed]] = []

    func candidates(for seeds: [QueueAutoplaySeed]) async throws -> [QueueAutoplayCandidate] {
        requests.append(seeds)
        let fresh = (1...max(1, poolSize)).prefix(poolSize).map { index in
            QueueAutoplayCandidate(
                track: MusicTrack(
                    id: "new-\(index)",
                    name: "New \(index)",
                    artists: ["Sample Artist \(index % 5)"],
                    albumArtworkURL: nil,
                    durationMilliseconds: 200_000,
                    isExplicit: false,
                    isPlayable: true,
                    linkedFromID: nil,
                    uri: "applemusic:song:new-\(index)"
                ),
                score: Double(1000 - index)
            )
        }
        let echoes = seeds.compactMap(\.uri).map { uri in
            QueueAutoplayCandidate(
                track: MusicTrack(
                    id: uri, name: uri, artists: ["Artist"], albumArtworkURL: nil, durationMilliseconds: 200_000,
                    isExplicit: false, isPlayable: true, linkedFromID: nil, uri: uri
                ),
                score: 5000
            )
        }
        return echoes + fresh
    }
}
