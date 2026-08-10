import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserArtistFallbackTests: XCTestCase {

    func testArtistDetailFallsBackToSearchWhenTopTracksForbidden() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "search-hit",
                            name: "Search Hit",
                            artists: ["Artist artist-xyz"],
                            artistRefs: [SpotifyArtistRef(id: "artist-xyz", name: "Artist artist-xyz")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 100_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:search-hit"
                        )
                    ],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case .loaded(.artist(let detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.title, "Search Hit")
    }

    func testArtistDetailFallsBackToAlbumsWhenTopTracksForbiddenAndSearchEmpty() async {
        let coverB = URL(string: "https://example.com/b.jpg")!
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "wrong",
                            name: "Wrong artist",
                            artists: ["Other"],
                            artistRefs: [SpotifyArtistRef(id: "other-artist", name: "Other")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 100_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:wrong"
                        )
                    ],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-b",
                        name: "Single 2021",
                        imageURL: coverB,
                        releaseYear: "2021",
                        totalTracks: 3,
                        group: .single,
                        uri: "spotify:album:alb-b"
                    ),
                    SpotifyArtistAlbum(
                        id: "alb-a",
                        name: "Album 2020",
                        imageURL: nil,
                        releaseYear: "2020",
                        totalTracks: 3,
                        group: .album,
                        uri: "spotify:album:alb-a"
                    ),
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                let aid = "artist-xyz"
                switch albumID {
                case "alb-b":
                    return [
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "A1", artistId: aid),
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t2", name: "A2", artistId: aid),
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t3", name: "Dup", artistId: aid),
                    ]
                case "alb-a":
                    return [
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t4", name: "B1", artistId: aid),
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t5", name: "B2", artistId: aid),
                        PlaylistBrowsingTestFixtures.fallbackTrack(id: "t6", name: "Dup", artistId: aid),
                    ]
                default:
                    return []
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case .loaded(.artist(let detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["A1", "A2", "Dup", "B1", "B2"])
        XCTAssertEqual(detail.tracks.first?.artworkURL, coverB)
    }

    func testArtistTopTracksForbiddenEntersCooldownAndSkipsRepeatedProbe() async {
        let now = Date(timeIntervalSince1970: 1_000)
        var currentTime = now
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "search-hit",
                            name: "Search Hit",
                            artists: ["Artist artist-xyz"],
                            artistRefs: [SpotifyArtistRef(id: "artist-xyz", name: "Artist artist-xyz")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 100_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:search-hit"
                        )
                    ],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { currentTime })

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(
            api.artistTopTracksCallCount, 1,
            "Second artist load during forbidden cooldown should skip top-tracks probe.")
        XCTAssertEqual(
            api.searchCallCount, 1,
            "Repeated artist opens within TTL should reuse cached detail instead of repeating fallback search.")
    }

    func testArtistTopTracksRateLimitedUsesReducedAlbumFallbackBudget() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.rateLimited(retryAfter: 1)
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-1"),
                    SpotifyArtistAlbum(
                        id: "alb-2", name: "A2", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-2"),
                    SpotifyArtistAlbum(
                        id: "alb-3", name: "A3", imageURL: nil, releaseYear: "2022", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-3"),
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [
                    PlaylistBrowsingTestFixtures.fallbackTrack(
                        id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")
                ]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.artistTopTracksCallCount, 1)
        XCTAssertEqual(api.searchCallCount, 1)
        XCTAssertEqual(
            api.albumTracksCallCount, 0,
            "Short-retry rate-limit should still avoid the per-album N+1; fallback uses one batched call.")
        XCTAssertEqual(
            api.albumsBatchedCallCount, 1,
            "Fallback collapses the rate-limited album loop into a single batched /v1/albums call.")
        XCTAssertEqual(
            api.albumsBatchedLastIDs?.count, 3, "Reduced budget caps batched IDs at 3 under rate-limit pressure.")
    }

    func testArtistAlbumFallbackDeduplicatesRepeatedAlbumIDs() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-dup", name: "Dup 2024", imageURL: nil, releaseYear: "2024", totalTracks: 1,
                        group: .album, uri: "spotify:album:alb-dup"),
                    SpotifyArtistAlbum(
                        id: "alb-dup", name: "Dup 2024 Deluxe", imageURL: nil, releaseYear: "2024", totalTracks: 9,
                        group: .album, uri: "spotify:album:alb-dup"),
                    SpotifyArtistAlbum(
                        id: "alb-unique", name: "Unique", imageURL: nil, releaseYear: "2023", totalTracks: 1,
                        group: .single, uri: "spotify:album:alb-unique"),
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [
                    PlaylistBrowsingTestFixtures.fallbackTrack(
                        id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")
                ]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(
            api.albumTracksCallCount, 0,
            "Fallback no longer issues per-album track requests; one batched call covers them.")
        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Fallback should make exactly one batched /v1/albums call.")
        XCTAssertEqual(
            api.albumsBatchedLastIDs, ["alb-dup", "alb-unique"],
            "Batched IDs should be deduplicated by album.id before the request.")
    }

    func testArtistTopTracksLongRateLimitSkipsAlbumFallbackEntirely() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                // Long Retry-After means Spotify is actively throttling; stacking the album fallback
                // onto the same back-off window would just earn another 429.
                throw SpotifyAPIError.rateLimited(retryAfter: 30)
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-1")
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [
                    PlaylistBrowsingTestFixtures.fallbackTrack(
                        id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")
                ]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.artistTopTracksCallCount, 1)
        XCTAssertEqual(api.searchCallCount, 1)
        XCTAssertEqual(
            api.albumTracksCallCount, 0, "Long-retry rate-limit must not cascade into per-album track fetches.")
        XCTAssertEqual(
            api.albumsBatchedCallCount, 0, "Long-retry rate-limit must skip the batched album fallback as well.")
        XCTAssertGreaterThanOrEqual(
            viewModel.artistFetchMetrics.albumFallbackBudgetStops, 1,
            "Skip should record exactly one budget stop for telemetry.")
    }

    func testArtistAlbumFallbackRecoversWhenBatchedResponseLacksTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-empty", name: "Empty 2024", imageURL: nil, releaseYear: "2024", totalTracks: 1,
                        group: .album, uri: "spotify:album:alb-empty"),
                    SpotifyArtistAlbum(
                        id: "alb-other", name: "Other 2023", imageURL: nil, releaseYear: "2023", totalTracks: 1,
                        group: .album, uri: "spotify:album:alb-other"),
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                // Only invoked by the recovery path. The recovery should target alb-empty (highest
                // priority album whose batched entry returned no tracks).
                XCTAssertEqual(
                    albumID, "alb-empty", "Recovery should target the empty-batched album in priority order.")
                return [
                    PlaylistBrowsingTestFixtures.fallbackTrack(id: "rec-1", name: "Recovered", artistId: "artist-xyz")
                ]
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        // alb-empty intentionally returns no tracks -> recovery candidate.
                        tracks: id == "alb-empty"
                            ? []
                            : [
                                PlaylistBrowsingTestFixtures.fallbackTrack(
                                    id: "track-\(id)", name: "Track \(id)", artistId: "artist-xyz")
                            ],
                        tracksAvailable: id != "alb-empty"
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Batched call should be issued once.")
        XCTAssertEqual(api.albumTracksCallCount, 1, "Recovery should issue exactly one single-album fallback request.")
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackBatchedCalls, 1)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackRecoveryCalls, 1)
    }

    func testArtistAlbumFallbackSkipsRecoveryWhenTracksFieldWasPresentButEmpty() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-present-empty", name: "Present Empty", imageURL: nil, releaseYear: "2024",
                        totalTracks: 1, group: .album, uri: "spotify:album:alb-present-empty")
                ]
            },
            albumTracksHandler: { _, _, _ in
                XCTFail("Recovery should not run when batched payload had tracksAvailable=true.")
                return []
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        tracks: [],
                        tracksAvailable: true
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0, "Recovery should be reserved for missing tracks payloads only.")
    }

    func testArtistAlbumFallbackBatchedRateLimitEntersCooldownAndSuppressesImmediateRetry() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-1")
                ]
            },
            albumsHandler: { _, _ in
                throw SpotifyAPIError.rateLimited(retryAfter: 30)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { clock })

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)
        XCTAssertEqual(
            api.albumsBatchedCallCount, 1,
            "Active cooldown should suppress immediate re-request of the same batched albums fallback.")

        clock = clock.addingTimeInterval(31)
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)
        XCTAssertEqual(
            api.albumsBatchedCallCount, 2, "After cooldown expires, fallback may probe the batched endpoint once again."
        )
    }

    func testArtistAlbumFallbackDoesNotLoopSingleAlbumRecoveryAcrossRepeatedRefreshes() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-empty", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album,
                        uri: "spotify:album:alb-empty")
                ]
            },
            albumTracksHandler: { _, _, _ in
                [PlaylistBrowsingTestFixtures.fallbackTrack(id: "rec-1", name: "Recovered", artistId: "artist-xyz")]
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        tracks: [],
                        tracksAvailable: false
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)

        XCTAssertEqual(api.albumsBatchedCallCount, 2, "Batched fallback can still run per refresh.")
        XCTAssertEqual(
            api.albumTracksCallCount, 1,
            "Single-album recovery must not loop repeatedly for the same album in one app session.")
    }

    func testArtistAlbumFallbackRendersFromStaleBatchedCacheUnderRateLimit() async {
        // When `/v1/albums?ids=...` is throttled, `SpotifyAPIClient.albums(...)` transparently serves
        // the prior cached body via its stale-on-rate-limit path (covered by the unit test in
        // `SpotifyWebAPIStepTests`). From the caller's perspective albums(...) just succeeds, so the
        // artist detail renders without triggering the cooldown breaker or any per-album recovery.
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-1", name: "Stale Album", imageURL: nil, releaseYear: "2024", totalTracks: 1,
                        group: .album, uri: "spotify:album:alb-1")
                ]
            },
            albumTracksHandler: { _, _, _ in
                XCTFail("Stale-on-rate-limit fallback delivers tracks; no per-album recovery should fire.")
                return []
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        tracks: [
                            PlaylistBrowsingTestFixtures.fallbackTrack(
                                id: "stale-\(id)", name: "Stale \(id)", artistId: "artist-xyz")
                        ],
                        tracksAvailable: true
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackBatchedCalls, 1)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackRecoveryCalls, 0)
        XCTAssertEqual(
            viewModel.artistFetchMetrics.albumFallbackBudgetStops, 0,
            "Stale-cache fallback succeeded; no budget stop should be recorded.")

        guard case .loaded(.artist(let detail)) = viewModel.detailState else {
            return XCTFail("Expected artist detail to load from the stale fallback path.")
        }
        XCTAssertEqual(
            detail.tracks.map(\.id), ["stale-alb-1"],
            "Tracks rendered for the artist must come from the stale batched body.")
    }

    func testSelectArtistSurfacesBadRequestWithCopyableDetails() async {
        let diagnosticDump = """
            GET https://api.spotify.com/v1/artists/x/albums?limit=50
            HTTP 400

            Response body:
            {"error":{"status":400,"message":"Invalid limit"}}
            """
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsHandler: { _, _, _ in
                throw SpotifyAPIError.badRequest(message: "Invalid limit", details: diagnosticDump)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-x")

        guard case .error(let error) = viewModel.detailState else {
            return XCTFail("Expected error detail state")
        }
        XCTAssertEqual(error.title, "Spotify rejected the request")
        XCTAssertEqual(error.message, "Invalid limit")
        XCTAssertFalse(error.canRetry)
        XCTAssertEqual(error.diagnosticDetails, diagnosticDump)
    }
}
