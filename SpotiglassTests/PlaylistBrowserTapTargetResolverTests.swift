import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserTapTargetResolverTests: XCTestCase {
    func testResolveArtistIDExactMatch() async throws {
        let results = MusicSearchResults(
            tracks: [],
            artists: [
                MusicArtist(id: "a1", name: "Taylor Swift", imageURL: nil, uri: "spotify:artist:a1"),
                MusicArtist(id: "a2", name: "Other", imageURL: nil, uri: "spotify:artist:a2")
            ],
            albums: [],
            playlists: []
        )
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Taylor Swift") { _, _ in results }
        XCTAssertEqual(id, "a1")
    }

    /// A search hit whose name is not the credit's is someone else: nothing opens (#637).
    func testResolveArtistIDIgnoresAnInexactFirstResult() async throws {
        let results = MusicSearchResults(
            tracks: [],
            artists: [MusicArtist(id: "a9", name: "Similar Name", imageURL: nil, uri: "spotify:artist:a9")],
            albums: [],
            playlists: []
        )
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Taylor") { _, _ in results }
        XCTAssertNil(id)
    }

    // MARK: - #637: "Bad Bunny & RaiNao" opened Mora

    private static func artist(_ id: String, _ name: String) -> MusicArtist {
        MusicArtist(id: id, name: name, imageURL: nil, uri: "music:artist:\(id)")
    }

    /// The catalog as it answered in #637: the combined credit names no artist, and its search
    /// lists Mora first. Each artist's own name finds that artist.
    private static func catalogSearch(_ query: String) -> MusicSearchResults {
        let artists: [MusicArtist]
        switch query {
        case "Bad Bunny & RaiNao":
            artists = [artist("mora", "Mora"), artist("bad-bunny", "Bad Bunny"), artist("rainao", "RaiNao")]
        case "Bad Bunny":
            artists = [artist("bad-bunny", "Bad Bunny"), artist("mora", "Mora")]
        case "RaiNao":
            artists = [artist("rainao", "RaiNao")]
        case "Simon & Garfunkel":
            artists = [artist("paul", "Paul Simon"), artist("sg", "Simon & Garfunkel")]
        case "Tyler, The Creator & Kali Uchis":
            artists = [artist("kali", "Kali Uchis"), artist("tyler-tc", "Tyler, The Creator")]
        case "Tyler":
            // Someone else who is called just that.
            artists = [artist("tyler", "Tyler")]
        default:
            artists = [artist("mora", "Mora")]
        }
        return MusicSearchResults(tracks: [], artists: artists, albums: [], playlists: [])
    }

    func testCombinedCreditOpensOneOfTheSongsArtistsNotTheFirstHit() async throws {
        var queries: [String] = []
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Bad Bunny & RaiNao") { query, _ in
            queries.append(query)
            return Self.catalogSearch(query)
        }
        XCTAssertEqual(id, "bad-bunny")
        // Plain names: Apple Music reads Spotify's `artist:"…"` filter as words to search. The
        // credit's own search already lists Bad Bunny, so no second search runs.
        XCTAssertEqual(queries, ["Bad Bunny & RaiNao"])
    }

    /// "Tyler" alone is someone else: the credit's search lists the real artist with the comma.
    func testANameWithACommaInACombinedCreditIsNotCutAtTheComma() async throws {
        var queries: [String] = []
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Tyler, The Creator & Kali Uchis") { query, _ in
            queries.append(query)
            return Self.catalogSearch(query)
        }
        XCTAssertEqual(id, "tyler-tc")
        XCTAssertEqual(queries, ["Tyler, The Creator & Kali Uchis"])
    }

    /// When the credit's search lists none of its artists, each name is searched on its own.
    func testEachNameIsSearchedWhenTheCreditsSearchListsNoneOfThem() async throws {
        var queries: [String] = []
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Nobody & RaiNao") { query, _ in
            queries.append(query)
            return Self.catalogSearch(query)
        }
        XCTAssertEqual(id, "rainao")
        XCTAssertEqual(queries, ["Nobody & RaiNao", "Nobody", "RaiNao"])
    }

    func testAnArtistNamedWithAnAmpersandOpensThatArtist() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Simon & Garfunkel") { query, _ in
            Self.catalogSearch(query)
        }
        XCTAssertEqual(id, "sg")
    }

    func testACreditNoArtistMatchesOpensNothing() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Nobody & Noone") { query, _ in
            Self.catalogSearch(query)
        }
        XCTAssertNil(id)
    }

    func testCreditNamesSplitsTheUsualSeparators() {
        XCTAssertEqual(
            PlaylistBrowserTapTargetResolver.creditNames(" Bad Bunny & RaiNao "),
            ["Bad Bunny & RaiNao", "Bad Bunny", "RaiNao"]
        )
        XCTAssertEqual(
            PlaylistBrowserTapTargetResolver.creditNames("A feat. B, C x D"),
            ["A feat. B, C x D", "A", "B", "C", "D"]
        )
        XCTAssertEqual(PlaylistBrowserTapTargetResolver.creditNames("Florence and the Machine"), ["Florence and the Machine"])
        XCTAssertEqual(PlaylistBrowserTapTargetResolver.creditNames("  "), [])
    }

    func testCreditRunsKeepTheSeparatorsBetweenNames() {
        XCTAssertEqual(
            PlaylistBrowserTapTargetResolver.creditRuns("Tyler, The Creator & Kali Uchis"),
            [
                "Tyler, The Creator & Kali Uchis", "Tyler, The Creator", "Tyler",
                "The Creator & Kali Uchis", "The Creator",
                "Kali Uchis",
            ]
        )
        XCTAssertEqual(PlaylistBrowserTapTargetResolver.creditRuns("  "), [])
    }

    /// The player bar's click on the combined credit, the whole way from the tap target.
    func testPlayerBarClickOnCombinedCreditOpensBadBunny() async {
        let nowPlaying = PlaybackNowPlaying(
            name: "PERFuMITO NUEVO",
            artists: ["Bad Bunny & RaiNao"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "music:song:1"
        )
        var opened: String?
        for target in nowPlaying.artistTapTargets {
            await PlaylistBrowserTapTargetNavigation.openArtist(
                target,
                origin: .extend,
                selectArtist: { id, _, _ in opened = id },
                resolveArtistID: { name in
                    try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: name) { query, _ in
                        Self.catalogSearch(query)
                    }
                }
            )
        }
        XCTAssertEqual(opened, "bad-bunny")
    }

    /// With the song's own artists, each is its own link with its ID: no search at all.
    func testNowPlayingWithTheSongsArtistsLinksEachByID() {
        let track = MusicTrack(
            id: "1",
            name: "PERFuMITO NUEVO",
            artists: ["Bad Bunny & RaiNao"],
            artistRefs: [MusicArtistRef(id: "bad-bunny", name: "Bad Bunny"), MusicArtistRef(id: "rainao", name: "RaiNao")],
            albumArtworkURL: nil,
            albumName: nil,
            albumID: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "music:song:1"
        )
        let snapshot = MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: true,
            item: .track(track),
            progressMilliseconds: 0
        )
        let nowPlaying = snapshot.playbackNowPlaying
        let expected = [ArtistTapTarget(id: "bad-bunny", name: "Bad Bunny"), ArtistTapTarget(id: "rainao", name: "RaiNao")]
        XCTAssertEqual(nowPlaying?.artistTapTargets, expected)
        // Moving the position keeps them, and so does the queue's copy of the item.
        XCTAssertEqual(nowPlaying?.with(positionMilliseconds: 5_000).artistTapTargets, expected)
        XCTAssertEqual(nowPlaying.map { QueueItem.from(playback: $0).artistTapTargets }, expected)
    }

    /// Spotify's player sends each artist's URI; the player bar links them by ID.
    func testSpotifyPlayerStateCarriesArtistIDs() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "track": [
                    "name": "PERFuMITO NUEVO",
                    "artists": ["Bad Bunny", "RaiNao"],
                    "artistRefs": [
                        ["name": "Bad Bunny", "uri": "spotify:artist:4q3ewBCX7sLwd24euuV69X"],
                        ["name": "RaiNao", "uri": "spotify:artist:rainao"],
                        ["name": "No URI"],
                    ],
                    "durationMilliseconds": 200_000,
                    "positionMilliseconds": 0,
                    "uri": "spotify:track:1",
                ],
                "nextTracks": [
                    [
                        "name": "Next",
                        "artists": ["RaiNao"],
                        "artistRefs": [["name": "RaiNao", "uri": "spotify:artist:rainao"]],
                        "durationMilliseconds": 100_000,
                        "positionMilliseconds": 0,
                        "uri": "spotify:track:2",
                    ],
                ],
            ],
        ])
        guard case let .stateChanged(nowPlaying, _, nextTracks) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertEqual(
            nowPlaying?.artistTapTargets,
            [ArtistTapTarget(id: "4q3ewBCX7sLwd24euuV69X", name: "Bad Bunny"), ArtistTapTarget(id: "rainao", name: "RaiNao")]
        )
        XCTAssertEqual(nextTracks.first?.artistTapTargets, [ArtistTapTarget(id: "rainao", name: "RaiNao")])
    }

    /// Apple Music queue entries come without artists: they are read once per song and then
    /// fill the track, so the player bar and queue link each artist by ID.
    func testAppleMusicSongArtistsAreReadOnceAndFillTheTrack() async {
        let songArtists = AppleMusicSongArtists()
        let track = MusicTrack(
            id: "1",
            name: "PERFuMITO NUEVO",
            artists: ["Bad Bunny & RaiNao"],
            albumArtworkURL: nil,
            albumName: nil,
            albumID: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "music:song:1"
        )
        let refs = [MusicArtistRef(id: "bad-bunny", name: "Bad Bunny"), MusicArtistRef(id: "rainao", name: "RaiNao")]
        var loads = 0
        let loaded = expectation(description: "artists read")
        let load: AppleMusicSongArtists.Load = {
            loads += 1
            loaded.fulfill()
            return refs
        }

        // Not known yet: the track stays as it came while its artists load.
        XCTAssertEqual(songArtists.filling(track, songID: "1", load: load).artistRefs, [])
        XCTAssertEqual(songArtists.filling(track, songID: "1", load: load).artistRefs, [])
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(songArtists.filling(track, songID: "1", load: load).artistRefs, refs)
        XCTAssertEqual(loads, 1)
    }

    func testAppleMusicSongArtistsRememberASongWithNoneAndAskOnce() async {
        let songArtists = AppleMusicSongArtists()
        var loads = 0
        let loaded = expectation(description: "artists read")
        let load: AppleMusicSongArtists.Load = {
            loads += 1
            loaded.fulfill()
            return []
        }
        XCTAssertNil(songArtists.artists(ofSong: "x", load: load))
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(songArtists.artists(ofSong: "x", load: load), [])
        XCTAssertEqual(loads, 1)
    }

    func testResolveArtistIDEmptyNameReturnsNil() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "   ") { _, _ in
            XCTFail("search should not run")
            return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertNil(id)
    }

    func testResolveAlbumIDWithArtistHintBuildsQuery() async throws {
        var capturedQuery = ""
        let album = MusicAlbum(id: "alb1", name: "Midnights", artists: ["Taylor Swift"], imageURL: nil, uri: "spotify:album:alb1")
        let id = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: "Midnights", artistHint: "Taylor Swift") { query, limit in
            capturedQuery = query
            XCTAssertEqual(limit, 10)
            return MusicSearchResults(tracks: [], artists: [], albums: [album], playlists: [])
        }
        XCTAssertEqual(capturedQuery, "album:\"Midnights\" artist:\"Taylor Swift\"")
        XCTAssertEqual(id, "alb1")
    }

    func testResolveAlbumIDWithoutArtistUsesAlbumOnlyQuery() async throws {
        var capturedQuery = ""
        _ = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: "Greatest Hits", artistHint: "") { query, _ in
            capturedQuery = query
            return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertEqual(capturedQuery, "album:\"Greatest Hits\"")
    }

    func testResolveAlbumIDNoResultsReturnsNil() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: "Missing", artistHint: "") { _, _ in
            MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertNil(id)
    }
}
