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
        libraryRowOrder = PlaylistBrowserLibraryActions.libraryRowOrderAfterSync(
            existing: libraryRowOrder,
            visiblePinnedItemIDs: visiblePinnedLibraryItems.map(\.id)
        )
    }

    func handleLibraryTransferDrop(_ transfers: [LibrarySidebarRowTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let moved = PlaylistBrowserLibraryActions.updatedOrderForLibraryTransferDrop(
            order: libraryRowOrder,
            transfers: transfers,
            insertionIndex: insertionIndex
        ) else { return false }
        libraryRowOrder = moved
        return true
    }

    func handlePinnedTransferDrop(_ transfers: [PinnedItemTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let application = PlaylistBrowserLibraryActions.pinnedTransferDropApplication(
            order: libraryRowOrder,
            transfers: transfers,
            insertionIndex: insertionIndex
        ) else { return false }

        if let itemID = application.reorderItemID, let index = application.reorderToIndex {
            pinnedStore.reorder(itemID: itemID, toInsertionIndex: index)
            libraryRowOrder = application.libraryRowOrder
        } else if let item = application.pinItem, let index = application.pinAtIndex {
            guard pinnedStore.pin(item, at: index) else { return false }
            syncLibraryRowOrder()
        }
        return true
    }

    func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        PlaylistBrowserLibraryActions.playlistSummaryFromRow(row)
    }
}
