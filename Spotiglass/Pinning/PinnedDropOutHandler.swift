import SwiftUI

/// View modifier that registers a drop destination for ``PinnedItemTransfer``
/// transfers that originated from the pinned sidebar. Dropping on this region
/// unpins the dragged item — used as the secondary "drag out" unpin gesture
/// alongside the hover-only ✕ badge.
struct PinnedDropOutHandler: ViewModifier {
    @ObservedObject var store: PinnedItemsStore

    func body(content: Content) -> some View {
        content.dropDestination(for: PinnedItemTransfer.self) { transfers, _ in
            guard let transfer = transfers.first, transfer.isFromPinnedSidebar else {
                return false
            }
            store.unpin(id: transfer.item.id)
            PinnedDragPreviewState.shared.endDrag()
            return true
        }
    }
}

extension View {
    /// Marks the receiver as an "unpin if dropped here" zone for pinned items.
    /// Used on the detail pane and the non-pinned sidebar regions.
    func acceptsPinnedDropOut(store: PinnedItemsStore) -> some View {
        modifier(PinnedDropOutHandler(store: store))
    }
}
