import SwiftUI
import AppKit

/// Renders the pinned-items list inside the existing Home `Section` of the
/// sidebar. Owns drag-to-reorder, the dashed insertion placeholder, and the
/// drop targets that accept either a reorder transfer (from the pinned area)
/// or a new-pin transfer (from any external draggable source).
struct SidebarPinnedRows: View {
    @ObservedObject var store: PinnedItemsStore
    /// Currently selected sidebar entry (used to highlight the matching pinned row).
    let sidebarSelection: SidebarSelection?

    @State private var dropInsertionIndex: Int?

    private let rowHeight: CGFloat = 64

    var body: some View {
        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
            if let dropInsertionIndex, dropInsertionIndex == index {
                insertionPlaceholder
            }
            row(for: item, at: index)
        }
        if let dropInsertionIndex, dropInsertionIndex == store.items.count {
            insertionPlaceholder
        }
    }

    @ViewBuilder
    private func row(for item: PinnedItem, at index: Int) -> some View {
        PinnedRowView(
            item: item,
            isSelected: sidebarSelection == .pinnedItem(item.id),
            onUnpin: { store.unpin(id: item.id) }
        )
        .tag(SidebarSelection.pinnedItem(item.id))
        .draggable(PinnedItemTransfer(item: item, originScopeID: PinnedItemTransfer.pinnedSidebarScopeID)) {
            PinnedItemDragPill(item: item)
        }
        .dropDestination(for: PinnedItemTransfer.self) { transfers, _ in
            handleDrop(transfers: transfers, at: index)
        } isTargeted: { isTargeted in
            if isTargeted {
                dropInsertionIndex = index
            } else if dropInsertionIndex == index {
                dropInsertionIndex = nil
            }
        }
        .contextMenu {
            Button("Unpin") { store.unpin(id: item.id) }
        }
    }

    private var insertionPlaceholder: some View {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
            .strokeBorder(
                SpotiglassDesign.controlAccent.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
            )
            .frame(height: 56)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private func handleDrop(transfers: [PinnedItemTransfer], at insertionIndex: Int) -> Bool {
        defer { dropInsertionIndex = nil }
        guard let transfer = transfers.first else { return false }
        if transfer.isFromPinnedSidebar {
            store.reorder(itemID: transfer.item.id, toInsertionIndex: insertionIndex)
        } else {
            store.pin(transfer.item, at: insertionIndex)
        }
        return true
    }
}

/// Hovering "drop bar" rendered at the bottom of the pinned list when the
/// user drags below the last item; the row-level drop targets cover insertion
/// at index 0..<items.count, this view target covers `items.count`.
struct SidebarPinnedRowsTrailingDrop: View {
    @ObservedObject var store: PinnedItemsStore
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .frame(height: 12)
            .contentShape(Rectangle())
            .dropDestination(for: PinnedItemTransfer.self) { transfers, _ in
                guard let transfer = transfers.first else { return false }
                if transfer.isFromPinnedSidebar {
                    store.reorder(itemID: transfer.item.id, toInsertionIndex: store.items.count)
                } else {
                    store.pin(transfer.item, at: store.items.count)
                }
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .strokeBorder(
                            SpotiglassDesign.controlAccent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
            }
    }
}
