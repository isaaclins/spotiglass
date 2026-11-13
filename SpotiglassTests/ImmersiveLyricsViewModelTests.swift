import XCTest

@testable import Spotiglass

@MainActor
final class ImmersiveLyricsViewModelTests: XCTestCase {
    private static let suiteLock = NSLock()

    override func setUp() {
        Self.suiteLock.lock()
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.setUp()
        AppKitTestSupport.pumpRunLoop(for: 0.1)
    }

    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.tearDown()
        Self.suiteLock.unlock()
    }

    private func sampleTrack(spotifyID: String = "lyricsTestId") -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Title",
            artists: ["Artist"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:\(spotifyID)"
        )
    }

    func testLoadRejectsNonMusicTrack() async {
        let vm = ImmersiveLyricsViewModel { _ in
            XCTFail("fetch should not run for non-track URIs")
            return .instrumental
        }
        let episode = PlaybackNowPlaying(
            name: "Pod",
            artists: ["Host"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:episode:abc"
        )
        await vm.load(track: episode)
        guard case let .failed(message) = vm.phase else {
            XCTFail("expected .failed, got \(vm.phase)")
            return
        }
        XCTAssertTrue(message.string.contains("music tracks"))
    }

    func testPreloadThenLoadUsesSingleNetworkFetch() async {
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel { _ in
            fetchCount += 1
            return .instrumental
        }
        let track = sampleTrack(spotifyID: "singleFetch")
        await vm.preload(track: track)
        await vm.load(track: track)
        XCTAssertEqual(fetchCount, 1)
        guard case let .ready(lyrics) = vm.phase else {
            XCTFail("expected .ready, got \(vm.phase)")
            return
        }
        XCTAssertEqual(lyrics, .instrumental)
    }

    func testCancelledTrackLoadCannotOverwriteCurrentPhaseOrTrackBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLyricsCancellationTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: directory)
        let gate = TrackLyricsFetchGate()
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { track in
            guard let trackID = track.lyricsTrackKey else {
                return .instrumental
            }
            await gate.fetchStarted(trackID)
            return try await gate.waitForResult(trackID)
        }, diskCache: disk)
        let trackA = sampleTrack(spotifyID: "cancelled-A")
        let trackB = sampleTrack(spotifyID: "current-B")

        let loadA = Task { await vm.load(track: trackA) }
        await gate.waitUntilStarted("cancelled-A")
        loadA.cancel()

        let loadB = Task { await vm.load(track: trackB) }
        await gate.waitUntilStarted("current-B")
        await gate.release("current-B", result: .failure(.noLyrics))
        await loadB.value

        await gate.release("cancelled-A", result: .success(.unsyncedPlain(["Track A"])))
        await loadA.value

        guard case let .failed(message) = vm.phase else {
            return XCTFail("expected current track failure, got \(vm.phase)")
        }
        XCTAssertTrue(message.string.contains("No lyrics"))
        XCTAssertEqual(disk.load(trackKey: "cancelled-A"), .unsyncedPlain(["Track A"]))
        XCTAssertNil(disk.loadTrackBackoffMetadata(trackKey: "cancelled-A"))
        XCTAssertEqual(
            disk.loadTrackBackoffMetadata(trackKey: "current-B")?.failureClass,
            .noLyrics
        )
        try? FileManager.default.removeItem(at: directory)
    }

    func testSupersededFailureDoesNotRegisterTrackBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLyricsCancellationFailureTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: directory)
        let gate = TrackLyricsFetchGate()
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { track in
            guard let trackID = track.lyricsTrackKey else {
                return .instrumental
            }
            await gate.fetchStarted(trackID)
            return try await gate.waitForResult(trackID)
        }, diskCache: disk)
        let trackA = sampleTrack(spotifyID: "failed-A")
        let trackB = sampleTrack(spotifyID: "ready-B")

        let loadA = Task { await vm.load(track: trackA) }
        await gate.waitUntilStarted("failed-A")
        loadA.cancel()

        let loadB = Task { await vm.load(track: trackB) }
        await gate.waitUntilStarted("ready-B")
        await gate.release("failed-A", result: .failure(.http(503)))
        await loadA.value
        await gate.release("ready-B", result: .success(.instrumental))
        await loadB.value

        XCTAssertEqual(vm.phase, .ready(.instrumental))
        XCTAssertNil(disk.loadTrackBackoffMetadata(trackKey: "failed-A"))
        XCTAssertEqual(disk.load(trackKey: "ready-B"), .instrumental)
        XCTAssertNil(disk.loadTrackBackoffMetadata(trackKey: "ready-B"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testConcurrentPreloadsShareOneFetch() async {
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel { _ in
            fetchCount += 1
            return .unsyncedPlain(["One"])
        }
        let track = sampleTrack(spotifyID: "dedupeConcurrent")
        async let first: Void = vm.preload(track: track)
        async let second: Void = vm.preload(track: track)
        await first
        await second
        XCTAssertEqual(fetchCount, 1)
    }

    func testLoadUsesDiskCacheWithoutCallingFetch() async throws {
        let trackID = "diskHit-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsDiskTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        try disk.save(trackKey: trackID, lyrics: .instrumental)

        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            return .unsyncedPlain(["unexpected"])
        }, diskCache: disk)

        await vm.load(track: sampleTrack(spotifyID: trackID))

        XCTAssertEqual(fetchCount, 0)
        guard case let .ready(lyrics) = vm.phase else {
            return XCTFail("expected .ready, got \(vm.phase)")
        }
        XCTAssertEqual(lyrics, .instrumental)
        try? FileManager.default.removeItem(at: dir)
    }

    func testPreloadDoesNotSetPhaseToLoading() async {
        let gate = LyricsFetchTestGate()
        let vm = ImmersiveLyricsViewModel { _ in
            await gate.markFetchStarted()
            await gate.waitUntilRelease()
            return .instrumental
        }
        let track = sampleTrack(spotifyID: "phaseIdleDuringPreload")
        let preloadTask = Task { await vm.preload(track: track) }
        await gate.waitUntilFetchStarted()
        if case .loading = vm.phase {
            XCTFail("preload must not set phase to .loading while fetch is in flight")
        }
        await gate.releaseFetch()
        await preloadTask.value
    }

    func testNoLyricsCooldownPreventsImmediateRefetch() async {
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.noLyrics
        }
        let track = sampleTrack(spotifyID: "noLyricsCooldown")

        await vm.load(track: track)
        await vm.load(track: track)
        await vm.preload(track: track)

        XCTAssertEqual(fetchCount, 1, "No-lyrics cooldown should suppress immediate repeated lookups.")
        guard case let .failed(message) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertTrue(message.string.contains("No lyrics"))
    }

    // MARK: - Failure backoff classification
    //
    // A server outage must not be treated like a missing lyric, so the class of
    // failure decides how long the track is suppressed for.

    private func backoffClass(
        after failure: LrcLibClient.Failure,
        trackID: String
    ) async throws -> LyricsDiskCache.TrackBackoffMetadata {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLyricsBackoff-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in throw failure }, diskCache: disk)

        await vm.load(track: sampleTrack(spotifyID: trackID))

        return try XCTUnwrap(
            disk.loadTrackBackoffMetadata(trackKey: trackID),
            "A failed load should record backoff metadata."
        )
    }

    func testServerErrorBacksOffAsTransient() async throws {
        let metadata = try await backoffClass(after: .http(503), trackID: "backoff-5xx")
        XCTAssertEqual(metadata.failureClass, .transient, "A 5xx is the server's problem and should be retried.")
        XCTAssertEqual(metadata.failureCount, 1)
    }

    func testClientErrorBacksOffAsPermanent() async throws {
        let metadata = try await backoffClass(after: .http(404), trackID: "backoff-4xx")
        XCTAssertEqual(metadata.failureClass, .permanent, "A 4xx will not change by retrying soon.")
    }

    func testRateLimitBacksOffAsRateLimited() async throws {
        let metadata = try await backoffClass(after: .rateLimited(retryAfter: 30), trackID: "backoff-429")
        XCTAssertEqual(metadata.failureClass, .rateLimited)
        XCTAssertGreaterThan(
            metadata.nextEligibleFetchAt.timeIntervalSinceNow,
            0,
            "A rate limit must hold the track back until the cooldown passes."
        )
    }

    func testInvalidURLBacksOffAsPermanent() async throws {
        let metadata = try await backoffClass(after: .invalidURL, trackID: "backoff-url")
        XCTAssertEqual(metadata.failureClass, .permanent)
    }

    func testNoLyricsCooldownPersistsToDiskAndSuppressesRefetch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsMissTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.noLyrics
        }, diskCache: disk)
        let trackID = "noLyricsDiskCooldown"
        let track = sampleTrack(spotifyID: trackID)

        await vm.load(track: track)
        ImmersiveLyricsViewModel.resetSharedStateForTesting()

        let vmAfterRestart = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.noLyrics
        }, diskCache: disk)
        await vmAfterRestart.load(track: track)

        XCTAssertEqual(fetchCount, 1, "Persisted miss cooldown should prevent immediate refetch after state reset.")
        try? FileManager.default.removeItem(at: dir)
    }

    func testLyricsDiskCacheMissCooldownRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsMissRoundTrip-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        let now = Date()
        let expiry = now.addingTimeInterval(120)

        XCTAssertNil(disk.loadMissCooldownExpiry(trackKey: "track-miss"))
        try disk.saveMissCooldownExpiry(trackKey: "track-miss", expiresAt: expiry)
        let loaded = disk.loadMissCooldownExpiry(trackKey: "track-miss")
        XCTAssertNotNil(loaded)
        if let loaded {
            XCTAssertEqual(loaded.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 0.5)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testRateLimitedBackoffSuppressesImmediateRefetch() async {
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.rateLimited(retryAfter: 300)
        }
        let track = sampleTrack(spotifyID: "rateLimitedCooldown")

        await vm.load(track: track)
        await vm.load(track: track)
        await vm.preload(track: track)

        XCTAssertEqual(fetchCount, 1, "Rate-limited cooldown should suppress immediate repeated lookups.")
        guard case let .failed(message) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertTrue(message.string.contains("rate limited"))
    }

    func testTrackBackoffMetadataPersistsToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsBackoffTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.decoding
        }, diskCache: disk)
        let track = sampleTrack(spotifyID: "decodingPersistedBackoff")

        await vm.load(track: track)
        ImmersiveLyricsViewModel.resetSharedStateForTesting()

        let vmAfterRestart = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            throw LrcLibClient.Failure.decoding
        }, diskCache: disk)
        await vmAfterRestart.load(track: track)

        XCTAssertEqual(fetchCount, 1, "Persisted per-track backoff should suppress immediate refetch after state reset.")
        try? FileManager.default.removeItem(at: dir)
    }

    func testLyricsDiskCacheTrackBackoffMetadataRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsBackoffRoundTrip-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        let nextEligible = Date().addingTimeInterval(90)
        let metadata = LyricsDiskCache.TrackBackoffMetadata(
            failureClass: .transient,
            failureCount: 3,
            nextEligibleFetchAt: nextEligible
        )

        XCTAssertNil(disk.loadTrackBackoffMetadata(trackKey: "track-backoff"))
        try disk.saveTrackBackoffMetadata(trackKey: "track-backoff", metadata: metadata)
        let loaded = disk.loadTrackBackoffMetadata(trackKey: "track-backoff")
        XCTAssertEqual(loaded?.failureClass, .transient)
        XCTAssertEqual(loaded?.failureCount, 3)
        XCTAssertEqual(loaded?.nextEligibleFetchAt.timeIntervalSince1970 ?? 0, metadata.nextEligibleFetchAt.timeIntervalSince1970, accuracy: 0.5)
        try disk.clearTrackBackoffMetadata(trackKey: "track-backoff")
        XCTAssertNil(disk.loadTrackBackoffMetadata(trackKey: "track-backoff"))
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Bounds (#381)

    private func lyricsFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testLyricsDiskCacheShrinksPastItsByteBoundLeastRecentlyUsedFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsBound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try LyricsDiskCache(directory: dir)
        let now = Date()
        let lines = (0 ..< 40).map { "A line of lyrics number \($0)" }
        for index in 0 ..< 30 {
            let key = String(format: "track-%02d", index)
            try disk.save(trackKey: key, lyrics: .unsyncedPlain(lines))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(index - 30) * 60)],
                ofItemAtPath: dir.appendingPathComponent("\(key).json").path
            )
        }
        try disk.saveMissCooldownExpiry(trackKey: "no-lyrics-track", expiresAt: now.addingTimeInterval(600))
        try disk.saveTrackBackoffMetadata(
            trackKey: "failing-track",
            metadata: .init(failureClass: .transient, failureCount: 1, nextEligibleFetchAt: now.addingTimeInterval(600))
        )
        // The oldest song was just played again, so it counts as recently used.
        XCTAssertEqual(disk.load(trackKey: "track-00"), .unsyncedPlain(lines))
        let oneFile = try XCTUnwrap(try dir.appendingPathComponent("track-01.json").resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let maxBytes = Int64(oneFile * 10)

        disk.prune(now: now, maxBytes: maxBytes)

        let left = lyricsFiles(in: dir).filter { $0.hasPrefix("track-") }
        XCTAssertLessThanOrEqual(Int64(left.count * oneFile), maxBytes * 3 / 4)
        XCTAssertTrue(left.contains("track-00.json"))
        XCTAssertTrue(left.contains("track-29.json"))
        XCTAssertFalse(left.contains("track-01.json"))
        XCTAssertEqual(disk.load(trackKey: "track-29"), .unsyncedPlain(lines))
        XCTAssertNil(disk.load(trackKey: "track-01"))
        // The cooldown and backoff files bound themselves and are kept.
        XCTAssertNotNil(disk.loadMissCooldownExpiry(trackKey: "no-lyrics-track"))
        XCTAssertNotNil(disk.loadTrackBackoffMetadata(trackKey: "failing-track"))
    }

    func testLyricsDiskCacheDeletesLyricsUnusedPastMaxAge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsAge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try LyricsDiskCache(directory: dir)
        let now = Date()
        try disk.save(trackKey: "played-last-year", lyrics: .instrumental)
        try disk.save(trackKey: "played-today", lyrics: .instrumental)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-LyricsDiskCache.maxAge - 60)],
            ofItemAtPath: dir.appendingPathComponent("played-last-year.json").path
        )

        disk.prune(now: now)

        XCTAssertNil(disk.load(trackKey: "played-last-year"))
        XCTAssertEqual(disk.load(trackKey: "played-today"), .instrumental)
    }

    func testLyricsShownFromMemoryCountAsUsedOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsUse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try LyricsDiskCache(directory: dir)
        let lines = (0 ..< 40).map { "A line of lyrics number \($0)" }
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in .unsyncedPlain(lines) }, diskCache: disk)
        let tracks = (0 ..< 10).map { sampleTrack(spotifyID: String(format: "usedSong%02d", $0)) }
        func fileURL(_ track: PlaybackNowPlaying) throws -> URL {
            let key = try XCTUnwrap(track.lyricsTrackKey)
            return dir.appendingPathComponent("\(key.filter { $0.isLetter || $0.isNumber || $0 == "-" }).json")
        }

        // Ten songs played in order, the first one an hour ago.
        let now = Date()
        for (index, track) in tracks.enumerated() {
            await vm.load(track: track)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(index - 60) * 60)],
                ofItemAtPath: try fileURL(track).path
            )
        }
        // The first song is played again; its lyrics come from memory.
        await vm.load(track: tracks[0])
        guard case .ready = vm.phase else { return XCTFail("expected lyrics, got \(vm.phase)") }

        let oneFile = try XCTUnwrap(try fileURL(tracks[1]).resourceValues(forKeys: [.fileSizeKey]).fileSize)
        disk.prune(now: Date(), maxBytes: Int64(oneFile * 5))

        XCTAssertTrue(FileManager.default.fileExists(atPath: try fileURL(tracks[0]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fileURL(tracks[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fileURL(tracks[9]).path))
    }

    func testInMemoryLyricsAreBoundedAndOlderOnesFetchAgain() async {
        var fetched: [String] = []
        let vm = ImmersiveLyricsViewModel { track in
            fetched.append(track.uri ?? "")
            return .instrumental
        }
        let count = ImmersiveLyricsViewModel.maxMemoryEntries + 20
        for index in 0 ..< count {
            await vm.load(track: sampleTrack(spotifyID: "memoryBound\(index)"))
        }
        XCTAssertEqual(fetched.count, count)

        // The most recent song is still in memory; the first one was evicted and fetches again.
        await vm.load(track: sampleTrack(spotifyID: "memoryBound\(count - 1)"))
        XCTAssertEqual(fetched.count, count)
        await vm.load(track: sampleTrack(spotifyID: "memoryBound0"))
        XCTAssertEqual(fetched.count, count + 1)
        guard case .ready(.instrumental) = vm.phase else {
            return XCTFail("expected lyrics, got \(vm.phase)")
        }
    }
}

/// Synchronizes lyrics fetch tests so assertions can run while a fetch is in flight.
private actor LyricsFetchTestGate {
    private var fetchStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func markFetchStarted() {
        fetchStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilRelease() async {
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func releaseFetch() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor TrackLyricsFetchGate {
    private var startedTrackIDs: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: CheckedContinuation<Result<FetchedLyrics, LrcLibClient.Failure>, Never>] = [:]

    func fetchStarted(_ trackID: String) {
        startedTrackIDs.insert(trackID)
        let waiters = startWaiters.removeValue(forKey: trackID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted(_ trackID: String) async {
        if startedTrackIDs.contains(trackID) { return }
        await withCheckedContinuation { startWaiters[trackID, default: []].append($0) }
    }

    func waitForResult(_ trackID: String) async throws -> FetchedLyrics {
        let result = await withCheckedContinuation { continuation in
            releaseWaiters[trackID] = continuation
        }
        return try result.get()
    }

    func release(_ trackID: String, result: Result<FetchedLyrics, LrcLibClient.Failure>) {
        releaseWaiters.removeValue(forKey: trackID)?.resume(returning: result)
    }
}
