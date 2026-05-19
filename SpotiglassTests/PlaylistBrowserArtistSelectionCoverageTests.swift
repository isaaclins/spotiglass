import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserArtistSelectionCoverageTests: XCTestCase {
    func testSelectArtistUsesCachedSnapshotWithoutNetwork() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]],
            artistTopTracksHandler: { _, _ in
                XCTFail("Should not fetch when cache is fresh")
                return []
            }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = SpotifyArtistDetail(
            id: "artist-1",
            name: "Cached Artist",
            imageURL: nil,
            followersTotal: 10,
            genres: [],
            uri: "spotify:artist:artist-1"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: false,
            paging: nil
        )
        vm.cachedArtistSnapshots["artist-1"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "artist-1")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected cached artist detail")
        }
        XCTAssertEqual(detail.artist.name, "Cached Artist")
    }
}
