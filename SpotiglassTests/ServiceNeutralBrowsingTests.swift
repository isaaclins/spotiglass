import XCTest
@testable import Spotiglass

/// #388: the browsing and playback layers serve Spotify and Apple Music, so an error that names
/// no service is told in the words of the service it came from, a request the provider doesn't
/// offer belongs to neither, and the Spotify files written before the neutral names still load.
@MainActor
final class ServiceNeutralBrowsingTests: XCTestCase {
    /// Errors that carry no service of their own: a dropped or slow connection, and an answer
    /// that didn't decode. On main every one of them read as Spotify's ("The connection to
    /// Spotify timed out.") in the Apple Music player bar and queue.
    private static let serviceLessErrors: [Error] = [
        URLError(.timedOut),
        URLError(.cannotFindHost),
        URLError(.cannotConnectToHost),
        URLError(.secureConnectionFailed),
        URLError(.badServerResponse),
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "garbled")),
    ]

    override func tearDown() {
        MusicServiceSelection.current = .spotify
        super.tearDown()
    }

    func testAnAppleMusicFailureThatNamesNoServiceNeverReadsAsSpotify() {
        MusicServiceSelection.current = .appleMusic

        for error in Self.serviceLessErrors {
            let playback = PlaybackSessionViewModel.displayError(for: error)
            XCTAssertFalse(playback.message.contains("Spotify"), "\(error): \(playback.message)")
            let starting = PlaybackSessionViewModel.playbackHostConnectionFailedError(for: error)
            XCTAssertFalse(starting.message.contains("Spotify"), "\(error): \(starting.message)")
            let queue = QueueViewModel.displayError(for: error)
            XCTAssertFalse(queue?.message.contains("Spotify") ?? true, "\(error): \(String(describing: queue?.message))")
            let home: HomeSectionState<[TrackRowViewModel]> = PlaylistBrowserViewModel.homeSectionState(for: error)
            XCTAssertEqual(
                home,
                .failed(BrowsingDisplayError.appleMusic(for: error)?.message ?? ""),
                "\(error)"
            )
        }
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: URLError(.timedOut)).message,
            SpotiglassL10n.string("appleMusic.error.network.message")
        )
        XCTAssertEqual(
            QueueViewModel.displayError(for: URLError(.badServerResponse))?.message,
            SpotiglassL10n.string("error.playback.appleMusic.failed")
        )
    }

    /// The player that failed names the service, not the one on screen: Apple Music can keep
    /// playing while Spotify is shown (#403), and the other way round.
    func testThePlayerThatFailedNamesTheServiceWhateverIsOnScreen() {
        MusicServiceSelection.current = .spotify
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: URLError(.timedOut), service: .appleMusic).message,
            SpotiglassL10n.string("appleMusic.error.network.message")
        )
        XCTAssertEqual(
            QueueViewModel.displayError(for: URLError(.timedOut), service: .appleMusic)?.message,
            SpotiglassL10n.string("appleMusic.error.network.message")
        )

        MusicServiceSelection.current = .appleMusic
        // Spotify's own wording stays for Spotify.
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: URLError(.timedOut), service: .spotify).message,
            SpotiglassL10n.string("auth.error.timeout")
        )
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: URLError(.badServerResponse), service: .spotify).message,
            SpotiglassL10n.string("error.playback.spotify.failed")
        )
        // A Spotify error is Spotify's wherever it shows.
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: SpotifyAPIError.network("x"), service: .appleMusic).message,
            SpotifyAPIError.network("x").userMessage
        )
    }

    /// On main a provider without an edit threw `SpotifyAPIError.invalidRequest`, so with Apple
    /// Music on screen the toast read "Library save is not supported by this API implementation."
    /// (English developer text) and the browser filed it under Spotify's errors.
    func testAnEditTheProviderDoesNotOfferReadsTheSameForEitherService() async {
        let row = TrackRowViewModel.numberedPlaylistRows([PlaylistBrowsingTestFixtures.track(id: "t1")])[0]
        let unsupported = SpotiglassL10n.string("error.browsing.unsupported")

        for service in [MusicService.appleMusic, .spotify] {
            MusicServiceSelection.current = service
            let viewModel = PlaylistBrowserViewModel(
                api: LimitCapturingBrowsingAPI(playlists: [], tracks: []),
                cache: MemoryBrowsingCache()
            )

            await viewModel.favoriteRows([row])
            XCTAssertEqual(viewModel.trackMutationToast, unsupported, "\(service)")

            do {
                try await viewModel.api.deletePlaylist(playlistID: "p1")
                XCTFail("Expected the default to throw")
            } catch {
                XCTAssertTrue(error is MusicBrowsingError, "\(error)")
                let shown = PlaylistBrowserViewModel.displayError(for: error)
                XCTAssertEqual(shown.message, unsupported, "\(service)")
                XCTAssertEqual(shown.title, SpotiglassL10n.string("error.browsing.generic.title"), "\(service)")
                XCTAssertFalse(shown.canRetry)
            }
        }
    }

    /// Spotify's playlist list as 0.8.0 writes it to disk: the neutral cache type reads it,
    /// shows it without asking Spotify again, and the account ID comes from the profile.
    func testSpotifyFilesWrittenByEarlierVersionsStillLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotiglass-388-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cachedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let written = """
        {
          "cachedAt" : "\(cachedAt)",
          "playlists" : [
            {
              "id" : "37i9dQZF1DXcBWIGoYBM5M",
              "imageURL" : "https://i.scdn.co/image/ab67706f00000002",
              "name" : "Road Trip",
              "ownerID" : "u",
              "ownerName" : "Me",
              "snapshotID" : "MTAsZDVmZDA",
              "trackCount" : 12
            }
          ]
        }
        """
        try Data(written.utf8).write(to: root.appendingPathComponent("playlists.json"))

        let api = LimitCapturingBrowsingAPI(playlists: [], tracks: [])
        let cache: any MusicBrowsingCache = try SpotifyLocalCache(rootDirectory: root)
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)
        await viewModel.load()

        XCTAssertEqual(viewModel.visiblePlaylists.map(\.id), ["37i9dQZF1DXcBWIGoYBM5M"])
        XCTAssertEqual(viewModel.playlistsByID["37i9dQZF1DXcBWIGoYBM5M"]?.trackCount, 12)
        XCTAssertEqual(viewModel.currentUserID, "u")
    }

    /// Spotify's scope rule is mapped into the neutral edit check: the same edits as before need
    /// the same scopes, and a session that has them goes ahead.
    func testSpotifyScopesMapIntoTheNeutralEditCheck() async {
        let readOnly = SpotifyLibraryEditPermissions(scopes: StaticSpotifyScopeProvider(scopes: ["playlist-read-private"]))
        let failure = await readOnly.missingPermission(for: .addToPlaylist)
        guard case let .insufficientScope(missing, _, _) = failure as? SpotifyAPIError else {
            return XCTFail("Expected a missing scope, got \(String(describing: failure))")
        }
        XCTAssertEqual(Set(missing), Set(SpotifyAuthConfiguration.requiredPlaylistModifyScopes))
        let noScopeNeeded = await readOnly.missingPermission(for: .deletePlaylist)
        XCTAssertNil(noScopeNeeded)

        let granted = SpotifyLibraryEditPermissions(scopes: StaticSpotifyScopeProvider(scopes: Set(
            SpotifyAuthConfiguration.requiredPlaylistModifyScopes + SpotifyAuthConfiguration.requiredSavedTracksModifyScopes
        )))
        for operation: PlaylistMutationOperation in [
            .addToPlaylist, .moveBetweenPlaylists, .renamePlaylist, .createPlaylist, .addToLikedSongs, .removeFromLikedSongs,
        ] {
            let allowed = await granted.missingPermission(for: operation)
            XCTAssertNil(allowed, "\(operation)")
        }
    }
}
