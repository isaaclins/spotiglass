import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserArtistFallbackTests: XCTestCase {

    func testArtistDetailUsesCatalogSearchWhenItFindsArtistTrack() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
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

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.title, "Search Hit")
    }

    func testArtistSelectionTreatsSearchCancellationAsNonErrorAndSkipsAlbumFallback() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                throw CancellationError()
            },
            artistAlbumsHandler: { _, _, _ in
                [SpotifyArtistAlbum(
                    id: "album-1",
                    name: "Album",
                    imageURL: nil,
                    releaseYear: "2024",
                    totalTracks: 1,
                    group: .album,
                    uri: "spotify:album:album-1"
                )]
            },
            albumTracksHandler: { _, _, _ in
                []
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumTracksCallCount, 0)
        guard case .loading = viewModel.detailState else {
            return XCTFail("Search cancellation should leave artist detail loading without publishing an error")
        }
    }

    func testArtistDetailFallsBackToSupportedAlbumTracksAfterEmptyCatalogSearch() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "album-new", name: "New", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:album-new"),
                    SpotifyArtistAlbum(id: "album-old", name: "Old", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:album-old")
                ]
            },
            albumTracksHandler: { albumID, _, limit in
                XCTAssertEqual(limit, 10)
                return [PlaylistBrowsingTestFixtures.fallbackTrack(
                    id: "track-\(albumID)",
                    name: "Dup",
                    artistId: "artist-xyz"
                )]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.map(\.id), ["track-album-new", "track-album-old"])
        XCTAssertEqual(detail.tracks.map(\.title), ["Dup", "Dup"])
        XCTAssertEqual(api.albumTracksCallCount, 2)
    }

    func testArtistFallbackDeduplicatesCanonicalTracksBeforeApplyingCap() async {
        let duplicate = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "same-track",
            name: "Dup",
            artistId: "artist-xyz"
        )
        let distinctTracks = (1 ... 10).map { index in
            PlaylistBrowsingTestFixtures.fallbackTrack(
                id: "distinct-\(index)",
                name: "Dup",
                artistId: "artist-xyz"
            )
        }
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [SpotifyArtistAlbum(
                    id: "album-one",
                    name: "Album",
                    imageURL: nil,
                    releaseYear: "2024",
                    totalTracks: 12,
                    group: .album,
                    uri: "spotify:album:album-one"
                )]
            },
            albumTracksHandler: { _, _, _ in
                [duplicate, duplicate] + distinctTracks
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.count, 10)
        XCTAssertEqual(detail.tracks.map(\.id), ["same-track"] + (1 ... 9).map { "distinct-\($0)" })
    }

    func testArtistDetailSurfacesAlbumTrackFailureInsteadOfShowingValidEmptyTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [SpotifyArtistAlbum(
                    id: "album-1",
                    name: "Album",
                    imageURL: nil,
                    releaseYear: "2024",
                    totalTracks: 1,
                    group: .album,
                    uri: "spotify:album:album-1"
                )]
            },
            albumTracksHandler: { _, _, _ in
                throw SpotifyAPIError.network("Album tracks unavailable")
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case let .error(error) = viewModel.detailState else {
            return XCTFail("Expected album track failure to be visible")
        }
        XCTAssertEqual(error.message, "Album tracks unavailable")
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

        guard case let .error(error) = viewModel.detailState else {
            return XCTFail("Expected error detail state")
        }
        XCTAssertEqual(error.title, "Spotify rejected the request")
        XCTAssertEqual(error.message, "Invalid limit")
        XCTAssertFalse(error.canRetry)
        XCTAssertEqual(error.diagnosticDetails, diagnosticDump)
    }

    // MARK: - Album-derived fallback details

    func testFallbackPatchesMissingTrackArtworkFromItsAlbum() {
        let albumArtwork = URL(string: "https://example.com/album.jpg")!
        let ownArtwork = URL(string: "https://example.com/track.jpg")!
        let source = [
            Self.fallbackTrack(id: "no-art", name: "No Art", albumArtworkURL: nil),
            Self.fallbackTrack(id: "own-art", name: "Own Art", albumArtworkURL: ownArtwork)
        ]
        var collected: [SpotifyTrack] = []
        var seen: Set<String> = []

        PlaylistBrowserViewModel.appendUniqueFallbackTracks(
            from: source,
            albumArtworkFallback: albumArtwork,
            into: &collected,
            seen: &seen,
            limit: 10
        )

        XCTAssertEqual(collected.map(\.id), ["no-art", "own-art"])
        XCTAssertEqual(collected[0].albumArtworkURL, albumArtwork, "Artwork-less track should inherit the album image.")
        XCTAssertEqual(collected[1].albumArtworkURL, ownArtwork, "A track that ships artwork keeps its own.")
        // The patched copy must preserve every other field.
        XCTAssertEqual(collected[0].name, "No Art")
        XCTAssertEqual(collected[0].uri, "spotify:track:no-art")
        XCTAssertEqual(collected[0].durationMilliseconds, 123_000)
        XCTAssertEqual(collected[0].artists, ["Artist"])
    }

    func testFallbackLeavesArtworkUnchangedWithoutAnAlbumImage() {
        var collected: [SpotifyTrack] = []
        var seen: Set<String> = []

        PlaylistBrowserViewModel.appendUniqueFallbackTracks(
            from: [Self.fallbackTrack(id: "no-art", name: "No Art", albumArtworkURL: nil)],
            albumArtworkFallback: nil,
            into: &collected,
            seen: &seen,
            limit: 10
        )

        XCTAssertEqual(collected.count, 1)
        XCTAssertNil(collected[0].albumArtworkURL)
    }

    func testAlbumOrderBreaksSameYearTiesByTrackCountThenName() {
        let albums = [
            Self.fallbackAlbum(id: "c", name: "Charlie", year: "2020", totalTracks: 12),
            Self.fallbackAlbum(id: "a", name: "Alpha", year: "2020", totalTracks: 12),
            Self.fallbackAlbum(id: "s", name: "Short", year: "2020", totalTracks: 3),
            Self.fallbackAlbum(id: "new", name: "Newer", year: "2021", totalTracks: 20)
        ]

        let ordered = PlaylistBrowserViewModel.albumsForTrackFallback(from: albums, maxCount: 6)

        XCTAssertEqual(
            ordered.map(\.id),
            ["new", "s", "a", "c"],
            "Newest year first, then fewer tracks, then case-insensitive name."
        )
    }

    // MARK: - Fixtures

    private static func fallbackTrack(id: String, name: String, albumArtworkURL: URL?) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: name,
            artists: ["Artist"],
            artistRefs: [SpotifyArtistRef(id: "artist-1", name: "Artist")],
            albumArtworkURL: albumArtworkURL,
            durationMilliseconds: 123_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    private static func fallbackAlbum(id: String, name: String, year: String, totalTracks: Int) -> SpotifyArtistAlbum {
        SpotifyArtistAlbum(
            id: id,
            name: name,
            imageURL: nil,
            releaseYear: year,
            totalTracks: totalTracks,
            group: .album,
            uri: "spotify:album:\(id)"
        )
    }
}
