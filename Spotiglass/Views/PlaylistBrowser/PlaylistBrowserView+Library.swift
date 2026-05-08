import SwiftUI

extension PlaylistBrowserView {
    var likedSongsStubRow: PlaylistRowViewModel {
        PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
    }

    var visiblePinnedLibraryItems: [PinnedItem] {
        pinnedStore.items.filter { $0.id != PinnedItem.likedSongsID }
    }

    var libraryRows: [LibrarySidebarRow] {
        let pinnedByToken = Dictionary(uniqueKeysWithValues: visiblePinnedLibraryItems.map {
            (LibrarySidebarOrder.pinnedToken(for: $0.id), $0)
        })
        return libraryRowOrder.compactMap { token in
            switch token {
            case LibrarySidebarOrder.homeToken:
                return .home
            default:
                guard let item = pinnedByToken[token] else { return nil }
                return .pinned(item)
            }
        }
    }

    func syncLibraryRowOrder() {
        if pinnedStore.isPinned(id: PinnedItem.likedSongsID) {
            pinnedStore.unpin(id: PinnedItem.likedSongsID)
        }
        libraryRowOrder = LibrarySidebarOrder.normalizedOrder(
            existing: libraryRowOrder,
            pinnedItemIDs: visiblePinnedLibraryItems.map(\.id)
        )
    }

    func handleLibraryTransferDrop(_ transfers: [LibrarySidebarRowTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let transfer = transfers.first else { return false }
        let moved = LibrarySidebarOrder.moved(
            order: libraryRowOrder,
            movingToken: transfer.rowToken,
            toInsertionIndex: insertionIndex
        )
        guard moved != libraryRowOrder else { return false }
        libraryRowOrder = moved
        return true
    }

    func handlePinnedTransferDrop(_ transfers: [PinnedItemTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let transfer = transfers.first else { return false }
        let sourceToken = LibrarySidebarOrder.pinnedToken(for: transfer.item.id)
        let targetPinnedIndex = LibrarySidebarOrder.pinnedInsertionIndex(
            order: libraryRowOrder,
            movingPinnedToken: transfer.isFromPinnedSidebar ? sourceToken : nil,
            toInsertionIndex: insertionIndex
        )

        if transfer.isFromPinnedSidebar {
            let movedRows = LibrarySidebarOrder.moved(
                order: libraryRowOrder,
                movingToken: sourceToken,
                toInsertionIndex: insertionIndex
            )
            guard movedRows != libraryRowOrder else { return false }
            pinnedStore.reorder(itemID: transfer.item.id, toInsertionIndex: targetPinnedIndex)
            libraryRowOrder = movedRows
        } else {
            guard pinnedStore.pin(transfer.item, at: targetPinnedIndex) else { return false }
            syncLibraryRowOrder()
        }
        return true
    }

    /// Reconstructs a lightweight ``SpotifyPlaylistSummary`` from the visible
    /// row view-model so the pinned-item snapshot is fully populated even
    /// when the underlying summary cache has aged out. Field defaults match
    /// what `PinnedRowView` actually displays.
    func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: row.id,
            name: row.title,
            ownerName: row.owner,
            imageURL: row.artworkURL,
            trackCount: 0,
            snapshotID: row.snapshotID
        )
    }
}
