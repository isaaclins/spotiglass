import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPinnedSidebarPolicyTests: XCTestCase {
    func testPermanentPinnedLoadErrorTitles() {
        XCTAssertTrue(
            PlaylistBrowserPinnedSidebarPolicy.isPermanentPinnedLoadError(
                BrowsingDisplayError(title: "Not Found", message: "x", canRetry: false)
            )
        )
        XCTAssertTrue(
            PlaylistBrowserPinnedSidebarPolicy.isPermanentPinnedLoadError(
                BrowsingDisplayError(title: "Access Denied", message: "x", canRetry: false)
            )
        )
        XCTAssertFalse(
            PlaylistBrowserPinnedSidebarPolicy.isPermanentPinnedLoadError(
                BrowsingDisplayError(title: "Offline", message: "x", canRetry: true)
            )
        )
    }

    func testPermanentPinnedLoadErrorMessagePhrases() {
        XCTAssertTrue(
            PlaylistBrowserPinnedSidebarPolicy.isPermanentPinnedLoadError(
                BrowsingDisplayError(title: "Error", message: "Playlist is no longer accessible.", canRetry: false)
            )
        )
    }

    func testItemShouldBeMarkedStaleForErrorAndStaleCache() {
        let err = BrowsingDisplayError(title: "Not Found", message: "gone", canRetry: false)
        XCTAssertTrue(PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: .error(err)))

        let transient = BrowsingDisplayError(title: "Offline", message: "retry", canRetry: true)
        XCTAssertFalse(PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: .error(transient)))

        let cachedDetail = BrowsingDetailContent.playlist(PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                SpotifyPlaylistSummary(
                    id: "p", name: "P", ownerName: "O",
                    imageURL: nil, trackCount: 0, snapshotID: "s"
                )
            ),
            tracks: []
        ))
        XCTAssertTrue(
            PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(
                for: .staleCache(cachedDetail, err)
            )
        )
        XCTAssertFalse(
            PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(
                for: .staleCache(cachedDetail, nil)
            )
        )
        XCTAssertFalse(PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: .loading))
    }
}
