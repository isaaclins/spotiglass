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

    static func libraryRowOrderAfterSync(
        existing: [String],
        visiblePinnedItemIDs: [String]
    ) -> [String] {
        normalizedLibraryRowOrder(existing: existing, pinnedItemIDs: visiblePinnedItemIDs)
    }

    /// Applies a `List.onMove` reorder to the visible Library rows and returns
    /// the resulting row-order tokens. Built from the rendered rows (not raw
    /// order indices) so stale tokens in a persisted order can never shift the
    /// move target.
    static func movedLibraryRowOrder(
        rows: [LibrarySidebarRow],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [String] {
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        return moved.map(\.id)
    }

    static func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: row.id,
            name: row.title,
            ownerID: row.ownerID,
            ownerName: row.owner,
            imageURL: row.artworkURL,
            trackCount: 0,
            snapshotID: row.snapshotID
        )
    }
}
