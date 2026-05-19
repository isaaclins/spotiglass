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
        XCTAssertTrue(message.contains("music tracks"))
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
        try disk.save(spotifyTrackID: trackID, lyrics: .instrumental)

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
        XCTAssertTrue(message.contains("No lyrics"))
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

        XCTAssertNil(disk.loadMissCooldownExpiry(spotifyTrackID: "track-miss"))
        try disk.saveMissCooldownExpiry(spotifyTrackID: "track-miss", expiresAt: expiry)
        let loaded = disk.loadMissCooldownExpiry(spotifyTrackID: "track-miss")
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
        XCTAssertTrue(message.contains("rate limited"))
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

        XCTAssertNil(disk.loadTrackBackoffMetadata(spotifyTrackID: "track-backoff"))
        try disk.saveTrackBackoffMetadata(spotifyTrackID: "track-backoff", metadata: metadata)
        let loaded = disk.loadTrackBackoffMetadata(spotifyTrackID: "track-backoff")
        XCTAssertEqual(loaded?.failureClass, .transient)
        XCTAssertEqual(loaded?.failureCount, 3)
        XCTAssertEqual(loaded?.nextEligibleFetchAt.timeIntervalSince1970 ?? 0, metadata.nextEligibleFetchAt.timeIntervalSince1970, accuracy: 0.5)
        try disk.clearTrackBackoffMetadata(spotifyTrackID: "track-backoff")
        XCTAssertNil(disk.loadTrackBackoffMetadata(spotifyTrackID: "track-backoff"))
        try? FileManager.default.removeItem(at: dir)
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
        waiters.forEach { $0.resume() }
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
