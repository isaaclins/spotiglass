import SwiftUI

extension PlaylistBrowserView {
    var likedSongsStubRow: PlaylistRowViewModel {
        PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
    }

    var visiblePinnedLibraryItems: [PinnedItem] {
        PlaylistBrowserLibraryActions.visiblePinnedLibraryItems(from: pinnedStore.items)
    }

    var libraryRows: [LibrarySidebarRow] {
        PlaylistBrowserLibraryActions.libraryRows(order: libraryRowOrder, pinnedItems: pinnedStore.items)
    }

    /// Mirrors the track table's selection into the command palette manager so
    /// the menu bar can enable and re-title its selection items (#132).
    func syncTrackSelectionMenuState() {
        let rows = viewModel.selectedTrackRows
        commandPaletteManager.canEnqueueTrackSelection = Self.canEnqueueTrackSelection(
            rows: rows,
            hasPlaybackDevice: hasPlaybackDevice
        )
        commandPaletteManager.trackSelectionPinState = Self.trackSelectionPinState(
            for: rows.compactMap { $0.pinnedTrackItem() },
            isPinned: { pinnedStore.isPinned(id: $0) }
        )
    }

    /// Queueing needs both a row that can be played and somewhere to play it.
    /// Episodes and local files have no playable URI, and with no active device
    /// there is nothing to queue onto, which is what the row context menu has
    /// always checked.
    static func canEnqueueTrackSelection(
        rows: [TrackRowViewModel],
        hasPlaybackDevice: Bool
    ) -> Bool {
        hasPlaybackDevice && rows.contains { $0.playableURI != nil }
    }

    /// Unpin only when every pinnable row is already pinned. A mixed selection
    /// offers Pin, so one command cannot both pin and unpin in a single press.
    ///
    /// Extracted as a static function because the rule is what matters and a
    /// SwiftUI view body is not a thing tests can ask questions of.
    static func trackSelectionPinState(
        for items: [PinnedItem],
        isPinned: (String) -> Bool
    ) -> TrackSelectionPinState {
        guard !items.isEmpty else { return .unavailable }
        return items.allSatisfy { isPinned($0.id) } ? .unpin : .pin
    }

    /// Unsave only when every catalog track in the selection is already saved.
    /// A mixed selection offers Add, so one command cannot both save and unsave
    /// tracks in a single press.
    static func trackSelectionLikedState(
        for rows: [TrackRowViewModel],
        isSaved: (String) -> Bool
    ) -> TrackSelectionLikedState {
        let ids = rows.compactMap { row -> String? in
            guard let uri = row.playableURI,
                  uri.hasPrefix("spotify:track:") else { return nil }
            let id = String(uri.dropFirst("spotify:track:".count))
            return id.isEmpty ? nil : id
        }
        guard !ids.isEmpty else { return .unavailable }
        return ids.allSatisfy(isSaved) ? .remove : .add
    }

    func syncLibraryRowOrder() {
        if pinnedStore.isPinned(id: PinnedItem.likedSongsID) {
            pinnedStore.unpin(id: PinnedItem.likedSongsID)
        }
        var existing = libraryRowOrder
        if let userID = pinnedStore.boundUserID, libraryRowOrderSeededUserID != userID {
            existing = LibraryRowOrderStore.load(userID: userID) ?? existing
            libraryRowOrderSeededUserID = userID
        }
        libraryRowOrder = PlaylistBrowserLibraryActions.libraryRowOrderAfterSync(
            existing: existing,
            visiblePinnedItemIDs: visiblePinnedLibraryItems.map(\.id)
        )
        persistLibraryRowOrder()
    }

    func persistLibraryRowOrder() {
        guard let userID = pinnedStore.boundUserID else { return }
        LibraryRowOrderStore.save(libraryRowOrder, userID: userID)
    }

    /// Applies a native `List.onMove` reorder of the Library section. The row
    /// order is rebuilt from the moved visible rows (never from raw indices
    /// into `libraryRowOrder`, which may contain stale tokens), and the
    /// pinned store is reconciled so its order matches the visible one.
    func moveLibraryRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        libraryRowOrder = PlaylistBrowserLibraryActions.movedLibraryRowOrder(
            rows: libraryRows,
            fromOffsets: source,
            toOffset: destination
        )
        pinnedStore.applyOrder(libraryRowOrder.compactMap(LibrarySidebarOrder.pinnedItemID(from:)))
        persistLibraryRowOrder()
    }

    /// Drag-to-pin drop on the sidebar. New pins append to the store; the
    /// `pinnedStore.items` onChange then runs `syncLibraryRowOrder()`, which
    /// inserts the new token at the end of the pins group (above Home).
    func pinDroppedTransfers(_ transfers: [PinnedItemTransfer]) -> Bool {
        var pinnedAny = false
        for transfer in transfers where pinnedStore.pin(transfer.item) {
            pinnedAny = true
        }
        return pinnedAny
    }

    func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        PlaylistBrowserLibraryActions.playlistSummaryFromRow(row)
    }
}
