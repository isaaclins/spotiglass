import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaylistsSidebarSectionHeaderStates() throws {
        let refreshing = PlaylistsSidebarSectionHeader(
            playlistState: .refreshing([PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "p", name: "Mix")
            )])
        )
        ViewTestHost.host(refreshing)
        XCTAssertNoThrow(try refreshing.inspect().find(text: "Refreshing"))

        let stale = PlaylistsSidebarSectionHeader(
            playlistState: .staleCache(
                [],
                BrowsingDisplayError(title: "Stale", message: "Cached", canRetry: true)
            )
        )
        ViewTestHost.host(stale)
        XCTAssertNoThrow(try stale.inspect().find(text: "Showing cached data"))
    }

    func testLibraryHomeSidebarRow() throws {
        let row = LibraryHomeSidebarRow()
        ViewTestHost.host(row)
        XCTAssertNoThrow(try row.inspect().find(text: "Home"))
    }

    func testPlaylistsSidebarSectionContentLoaded() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let playbackVM = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let playlists = browserVM.playlistState.currentValue ?? []
        let content = PlaylistsSidebarSectionContent(
            playlistState: .loaded(playlists),
            likedSongsStubRow: PlaylistRowViewModel(
                likedSongsOwnerDisplay: "You",
                totalTrackCount: nil,
                artworkURL: nil
            ),
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            playlistSummaryFromRow: { row in
                SpotifyPlaylistSummary(
                    id: row.id,
                    name: row.title,
                    ownerName: row.owner,
                    imageURL: row.artworkURL,
                    trackCount: 0,
                    snapshotID: row.snapshotID
                )
            }
        )
        .environmentObject(store)
        ViewTestHost.host(content, size: CGSize(width: 320, height: 400))
        XCTAssertNoThrow(try content.inspect().find(text: "One"))
    }

    func testPlaylistsSidebarSectionContentLoadingAndError() throws {
        let browserVM = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let playbackVM = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let liked = PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
        let summary: (PlaylistRowViewModel) -> SpotifyPlaylistSummary = { row in
            SpotifyPlaylistSummary(
                id: row.id, name: row.title, ownerName: row.owner,
                imageURL: row.artworkURL, trackCount: 0, snapshotID: row.snapshotID
            )
        }
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let loading = PlaylistsSidebarSectionContent(
            playlistState: .loading,
            likedSongsStubRow: liked,
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            playlistSummaryFromRow: summary
        )
        .environmentObject(store)
        ViewTestHost.host(loading)
        XCTAssertNoThrow(try loading.inspect().find(text: "Loading playlists..."))

        let error = PlaylistsSidebarSectionContent(
            playlistState: .error(BrowsingDisplayError(title: "Oops", message: "Fail", canRetry: true)),
            likedSongsStubRow: liked,
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            playlistSummaryFromRow: summary
        )
        .environmentObject(store)
        ViewTestHost.host(error)
        XCTAssertNoThrow(try error.inspect().find(text: "Oops"))
    }

    func testPinnedSidebarLibraryRow() throws {
        let pin = PinnedItem.playlist(
            PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Pinned Mix")
        )
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "test-user")
        store.pin(pin)
        let row = PinnedSidebarLibraryRow(item: pin, isSelected: true)
            .environmentObject(store)
        ViewTestHost.host(row)
        XCTAssertNoThrow(try row.inspect().find(text: "Pinned Mix"))
    }
}
