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
}
