import Foundation

/// Pure library-sidebar helpers extracted from ``PlaylistBrowserView`` for unit testing.
enum PlaylistBrowserLibraryActions {
    static func visiblePinnedLibraryItems(from items: [PinnedItem]) -> [PinnedItem] {
        items.filter { $0.id != PinnedItem.likedSongsID }
    }

    static func libraryRows(
        order: [String],
        pinnedItems: [PinnedItem]
    ) -> [LibrarySidebarRow] {
        let pinnedByToken = Dictionary(uniqueKeysWithValues: visiblePinnedLibraryItems(from: pinnedItems).map {
            (LibrarySidebarOrder.pinnedToken(for: $0.id), $0)
        })
        return order.compactMap { token in
            switch token {
            case LibrarySidebarOrder.homeToken:
                return .home
            default:
                guard let item = pinnedByToken[token] else { return nil }
                return .pinned(item)
            }
        }
    }

    static func normalizedLibraryRowOrder(
        existing: [String],
        pinnedItemIDs: [String]
    ) -> [String] {
        LibrarySidebarOrder.normalizedOrder(existing: existing, pinnedItemIDs: pinnedItemIDs)
    }

    static func movedLibraryRowOrder(
        order: [String],
        transfer: LibrarySidebarRowTransfer,
        insertionIndex: Int
    ) -> [String]? {
        let moved = LibrarySidebarOrder.moved(
            order: order,
            movingToken: transfer.rowToken,
            toInsertionIndex: insertionIndex
        )
        guard moved != order else { return nil }
        return moved
    }

    static func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: row.id,
            name: row.title,
            ownerName: row.owner,
            imageURL: row.artworkURL,
            trackCount: 0,
            snapshotID: row.snapshotID
        )
    }

    struct PinnedTransferDropPlan: Equatable {
        var libraryRowOrder: [String]
        var pinnedReorderItemID: String?
        var pinnedReorderToIndex: Int?
        var pinItem: PinnedItem?
        var pinAtIndex: Int?
    }

    static func updatedOrderForLibraryTransferDrop(
        order: [String],
        transfers: [LibrarySidebarRowTransfer],
        insertionIndex: Int
    ) -> [String]? {
        guard let transfer = transfers.first else { return nil }
        return movedLibraryRowOrder(order: order, transfer: transfer, insertionIndex: insertionIndex)
    }

    struct PinnedTransferDropApplication: Equatable {
        var libraryRowOrder: [String]
        var reorderItemID: String?
        var reorderToIndex: Int?
        var pinItem: PinnedItem?
        var pinAtIndex: Int?
    }

    static func pinnedTransferDropApplication(
        order: [String],
        transfers: [PinnedItemTransfer],
        insertionIndex: Int
    ) -> PinnedTransferDropApplication? {
        guard let transfer = transfers.first,
              let plan = planPinnedTransferDrop(
                order: order,
                transfer: transfer,
                insertionIndex: insertionIndex
              )
        else { return nil }
        return PinnedTransferDropApplication(
            libraryRowOrder: plan.libraryRowOrder,
            reorderItemID: plan.pinnedReorderItemID,
            reorderToIndex: plan.pinnedReorderToIndex,
            pinItem: plan.pinItem,
            pinAtIndex: plan.pinAtIndex
        )
    }

    static func libraryRowOrderAfterSync(
        existing: [String],
        visiblePinnedItemIDs: [String]
    ) -> [String] {
        normalizedLibraryRowOrder(existing: existing, pinnedItemIDs: visiblePinnedItemIDs)
    }

    static func planPinnedTransferDrop(
        order: [String],
        transfer: PinnedItemTransfer,
        insertionIndex: Int
    ) -> PinnedTransferDropPlan? {
        let sourceToken = LibrarySidebarOrder.pinnedToken(for: transfer.item.id)
        let targetPinnedIndex = LibrarySidebarOrder.pinnedInsertionIndex(
            order: order,
            movingPinnedToken: transfer.isFromPinnedSidebar ? sourceToken : nil,
            toInsertionIndex: insertionIndex
        )

        if transfer.isFromPinnedSidebar {
            let movedRows = LibrarySidebarOrder.moved(
                order: order,
                movingToken: sourceToken,
                toInsertionIndex: insertionIndex
            )
            guard movedRows != order else { return nil }
            return PinnedTransferDropPlan(
                libraryRowOrder: movedRows,
                pinnedReorderItemID: transfer.item.id,
                pinnedReorderToIndex: targetPinnedIndex,
                pinItem: nil,
                pinAtIndex: nil
            )
        }
        return PinnedTransferDropPlan(
            libraryRowOrder: order,
            pinnedReorderItemID: nil,
            pinnedReorderToIndex: nil,
            pinItem: transfer.item,
            pinAtIndex: targetPinnedIndex
        )
    }
}
