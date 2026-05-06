import XCTest

@testable import Spotiglass

@MainActor
final class ImmersiveLyricsViewModelTests: XCTestCase {
    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.tearDown()
    }

    private func sampleTrack(spotifyID: String = "lyricsTestId") -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Title",
            artists: ["Artist"],
            albumName: "Album",
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
            try await Task.sleep(nanoseconds: 25_000_000)
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
            try await Task.sleep(nanoseconds: 35_000_000)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotiglassLyricsDiskTests-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: dir)
        try disk.save(spotifyTrackID: "diskHit", lyrics: .instrumental)

        var fetchCount = 0
        let vm = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            fetchCount += 1
            return .unsyncedPlain(["unexpected"])
        }, diskCache: disk)

        await vm.load(track: sampleTrack(spotifyID: "diskHit"))

        XCTAssertEqual(fetchCount, 0)
        guard case let .ready(lyrics) = vm.phase else {
            return XCTFail("expected .ready, got \(vm.phase)")
        }
        XCTAssertEqual(lyrics, .instrumental)
        try? FileManager.default.removeItem(at: dir)
    }

    func testPreloadDoesNotSetPhaseToLoading() async {
        let vm = ImmersiveLyricsViewModel { _ in
            try await Task.sleep(nanoseconds: 60_000_000)
            return .instrumental
        }
        let track = sampleTrack(spotifyID: "phaseIdleDuringPreload")
        let preloadTask = Task { await vm.preload(track: track) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        if case .loading = vm.phase {
            XCTFail("preload must not set phase to .loading")
        }
        await preloadTask.value
    }
}
