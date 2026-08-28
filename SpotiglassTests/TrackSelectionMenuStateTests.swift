import XCTest
@testable import Spotiglass

/// The menu bar's Add to Queue and Pin items act on the track table's
/// selection rather than a right-clicked row (#132). The part worth testing is
/// the rule that decides whether the item says Pin or Unpin, and whether it is
/// available at all.
@MainActor
final class TrackSelectionMenuStateTests: XCTestCase {

    private func makeTrack(id: String) -> SpotifyTrack {
        SpotifyTrack(
            id: id, name: "Song \(id)",
            artists: ["A"], albumArtworkURL: nil,
            durationMilliseconds: 1000, isExplicit: false, isPlayable: true,
            linkedFromID: nil, uri: "spotify:track:\(id)"
        )
    }

    private func makeItems(_ ids: [String]) -> [PinnedItem] {
        ids.map { PinnedItem.track(makeTrack(id: $0)) }
    }

    /// An empty selection has nothing to act on, so the item dims rather than
    /// running against nothing.
    func testEmptySelectionIsUnavailable() {
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(for: [], isPinned: { _ in true }),
            .unavailable
        )
    }

    func testUnpinnedSelectionOffersPin() {
        let items = makeItems(["t1", "t2"])
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(for: items, isPinned: { _ in false }),
            .pin
        )
    }

    func testFullyPinnedSelectionOffersUnpin() {
        let items = makeItems(["t1", "t2"])
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(for: items, isPinned: { _ in true }),
            .unpin
        )
    }

    /// The case that decides the design: with one row pinned and one not, the
    /// item must not be able to pin and unpin in the same press. It offers Pin,
    /// which is the direction that leaves every selected row pinned.
    func testMixedSelectionOffersPinRatherThanBoth() {
        let items = makeItems(["t1", "t2"])
        let pinnedIDs: Set<String> = ["track:t1"]
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(
                for: items,
                isPinned: { pinnedIDs.contains($0) }
            ),
            .pin
        )
    }

    /// Rows with no pinnable identity, such as local files, contribute no items,
    /// so a selection made only of those stays unavailable.
    func testSelectionWithNoPinnableRowsIsUnavailable() {
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(for: [], isPinned: { _ in false }),
            .unavailable
        )
    }

    // MARK: - Liked Songs state

    func testFullySavedSelectionOffersRemove() {
        let rows = [makeRow(id: "t1", playable: true), makeRow(id: "t2", playable: true)]
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionLikedState(
                for: rows,
                isSaved: { _ in true }
            ),
            .remove
        )
    }

    func testUnsavedSelectionOffersAdd() {
        let rows = [makeRow(id: "t1", playable: true), makeRow(id: "t2", playable: true)]
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionLikedState(
                for: rows,
                isSaved: { _ in false }
            ),
            .add
        )
    }

    func testMixedSavedSelectionOffersAddRatherThanBoth() {
        let rows = [makeRow(id: "t1", playable: true), makeRow(id: "t2", playable: true)]
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionLikedState(
                for: rows,
                isSaved: { $0 == "t1" }
            ),
            .add
        )
    }

    func testSelectionWithNoCatalogURIIsUnavailable() {
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionLikedState(
                for: [makeRow(id: "episode", playable: false)],
                isSaved: { _ in true }
            ),
            .unavailable
        )
    }

    func testSavedTrackStatusesAreStoredPerCatalogRow() async {
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [:],
            savedTrackStatusesHandler: { ids in
                ids.map { $0 == "saved" }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let rows = [makeRow(id: "saved", playable: true), makeRow(id: "new", playable: true)]

        await viewModel.loadSavedTrackStates(for: rows)

        XCTAssertEqual(viewModel.savedTrackStates, ["saved": true, "new": false])
        XCTAssertEqual(api.savedTrackStatusesCalls, [["saved", "new"]])
    }

    // MARK: - Add to Queue availability

    private func makeRow(id: String, playable: Bool) -> TrackRowViewModel {
        TrackRowViewModel(
            topTrack: SpotifyTrack(
                id: id, name: "Song \(id)",
                artists: ["A"], albumArtworkURL: nil,
                durationMilliseconds: 1000, isExplicit: false, isPlayable: playable,
                linkedFromID: nil, uri: "spotify:track:\(id)"
            ),
            listPosition: 1
        )
    }

    /// With no device there is nowhere to queue onto, which is the check the row
    /// context menu has always made and the menu bar item now makes too.
    func testEnqueueNeedsAPlaybackDevice() {
        let rows = [makeRow(id: "t1", playable: true)]
        XCTAssertFalse(
            PlaylistBrowserView.canEnqueueTrackSelection(rows: rows, hasPlaybackDevice: false)
        )
        XCTAssertTrue(
            PlaylistBrowserView.canEnqueueTrackSelection(rows: rows, hasPlaybackDevice: true)
        )
    }

    /// An unavailable row has no playable URI, so a selection made only of those
    /// offers nothing to queue even with a device connected.
    func testEnqueueNeedsAtLeastOnePlayableRow() {
        XCTAssertFalse(
            PlaylistBrowserView.canEnqueueTrackSelection(rows: [], hasPlaybackDevice: true)
        )
        XCTAssertFalse(
            PlaylistBrowserView.canEnqueueTrackSelection(
                rows: [makeRow(id: "t1", playable: false)],
                hasPlaybackDevice: true
            )
        )
        XCTAssertTrue(
            PlaylistBrowserView.canEnqueueTrackSelection(
                rows: [makeRow(id: "t1", playable: false), makeRow(id: "t2", playable: true)],
                hasPlaybackDevice: true
            ),
            "one playable row in a mixed selection is enough to offer the action"
        )
    }

}
