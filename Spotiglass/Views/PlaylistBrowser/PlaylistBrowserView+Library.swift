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
