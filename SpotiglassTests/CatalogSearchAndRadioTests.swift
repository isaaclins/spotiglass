import XCTest

@testable import Spotiglass

final class CatalogSearchAndRadioTests: XCTestCase {

    func testPerformCatalogSearchUpdatesState() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [:],
            searchHandler: { query, limit in
                XCTAssertEqual(query, "Daft Punk")
                return SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "t1",
                            name: "One More Time",
                            artists: ["Daft Punk"],
                            artistRefs: [SpotifyArtistRef(id: "art1", name: "Daft Punk")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 320_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:t1"
                        )
                    ],
                    artists: [
                        SpotifyArtist(id: "art1", name: "Daft Punk", imageURL: nil, uri: "spotify:artist:art1")
                    ],
                    albums: [],
                    playlists: []
                )
            }
        )
        let cache = MockBrowsingCache()
        let vm = PlaylistBrowserViewModel(api: api, cache: cache)

        vm.performCatalogSearch(query: "Daft Punk")

        // Wait for debounce and task execution
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(vm.searchCatalogResults.tracks.count, 1)
        XCTAssertEqual(vm.searchCatalogResults.tracks.first?.name, "One More Time")
        XCTAssertEqual(vm.searchCatalogResults.artists.count, 1)
        XCTAssertFalse(vm.isSearchingCatalog)
    }

    func testStartTrackRadioInvokesRecommendationsAndPlays() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [:]
        )
        let cache = MockBrowsingCache()
        let browserVM = PlaylistBrowserViewModel(api: api, cache: cache)

        let mockPlayback = MockSpotifyPlaybackAPI()
        let playbackVM = PlaybackSessionViewModel(api: mockPlayback, nowPlayingQueueID: "test")

        let seedTrack = TrackRowViewModel(
            listPosition: 1,
            title: "Instant Crush",
            artistsLine: "Daft Punk, Julian Casablancas",
            artistID: "art1",
            artistRefs: [SpotifyArtistRef(id: "art1", name: "Daft Punk")],
            albumTitle: "Random Access Memories",
            albumID: "alb1",
            duration: "5:37",
            durationMilliseconds: 337_000,
            isExplicit: false,
            isPlayable: true,
            artworkURL: nil,
            spotifyID: "t-instant",
            playableURI: "spotify:track:t-instant"
        )

        await browserVM.startTrackRadio(seedTrack: seedTrack, playbackViewModel: playbackVM)

        XCTAssertNotNil(browserVM.trackMutationToast)
        XCTAssertTrue(browserVM.trackMutationToast?.contains("Instant Crush") == true)
    }

    func testStartArtistRadioInvokesRadioAndPlays() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [:]
        )
        let cache = MockBrowsingCache()
        let browserVM = PlaylistBrowserViewModel(api: api, cache: cache)

        let mockPlayback = MockSpotifyPlaybackAPI()
        let playbackVM = PlaybackSessionViewModel(api: mockPlayback, nowPlayingQueueID: "test")

        await browserVM.startArtistRadio(artistID: "art1", artistName: "Daft Punk", playbackViewModel: playbackVM)

        XCTAssertNotNil(browserVM.trackMutationToast)
        XCTAssertTrue(browserVM.trackMutationToast?.contains("Daft Punk") == true)
    }
}
