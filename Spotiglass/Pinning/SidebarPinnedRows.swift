import SwiftUI
import AppKit

/// Builds and mutates the visible row order for the unified Library sidebar
/// section: Home, Liked Songs, and pinned entries.
enum LibrarySidebarOrder {
    static let homeToken = "library.home"
    static let likedSongsToken = "library.likedSongs"
    private static let pinnedPrefix = "pinned:"

    static func pinnedToken(for itemID: String) -> String {
        "\(pinnedPrefix)\(itemID)"
    }

    static func pinnedItemID(from token: String) -> String? {
        guard token.hasPrefix(pinnedPrefix) else { return nil }
        return String(token.dropFirst(pinnedPrefix.count))
    }

    static func normalizedOrder(existing: [String], pinnedItemIDs: [String]) -> [String] {
        let allowed = Set([homeToken, likedSongsToken] + pinnedItemIDs.map(pinnedToken(for:)))
        var filtered = existing.filter { allowed.contains($0) }
        var seen: Set<String> = []
        filtered = filtered.filter { seen.insert($0).inserted }

        let hasPinnedAlready = filtered.contains(where: { pinnedItemID(from: $0) != nil })
        if !hasPinnedAlready {
            // First synthesis after migration: preferred default is pinned first.
            filtered = pinnedItemIDs.map(pinnedToken(for:)) + [homeToken, likedSongsToken]
            seen = Set(filtered)
        }

        if !seen.contains(homeToken) {
            filtered.append(homeToken)
            seen.insert(homeToken)
        }
        if !seen.contains(likedSongsToken) {
            filtered.append(likedSongsToken)
            seen.insert(likedSongsToken)
        }

        for id in pinnedItemIDs {
            let token = pinnedToken(for: id)
            if seen.insert(token).inserted {
                filtered.append(token)
            }
        }
        return filtered
    }

    static func moved(order: [String], movingToken: String, toInsertionIndex insertionIndex: Int) -> [String] {
        guard let source = order.firstIndex(of: movingToken) else { return order }
        var without = order
        without.remove(at: source)
        let clamped = max(0, min(insertionIndex, without.count))
        without.insert(movingToken, at: clamped)
        return without
    }

    static func pinnedInsertionIndex(
        order: [String],
        movingPinnedToken: String?,
        toInsertionIndex insertionIndex: Int
    ) -> Int {
        var normalized = order
        if let movingPinnedToken, let idx = normalized.firstIndex(of: movingPinnedToken) {
            normalized.remove(at: idx)
        }
        let clamped = max(0, min(insertionIndex, normalized.count))
        return normalized.prefix(clamped).reduce(into: 0) { count, token in
            if pinnedItemID(from: token) != nil {
                count += 1
            }
        }
    }
}

/// Renders the pinned-items list inside the existing Home `Section` of the
/// sidebar. Owns drag-to-reorder, the dotted-outline drop-slot skeleton, and
/// the drop targets that accept either a reorder transfer (from the pinned
/// area) or a new-pin transfer (from any external draggable source).
struct SidebarPinnedRows: View {
    @ObservedObject var store: PinnedItemsStore
    /// Currently selected sidebar entry (used to highlight the matching pinned row).
    let sidebarSelection: SidebarSelection?
    @ObservedObject private var dragPreviewState = PinnedDragPreviewState.shared

    @State private var dropInsertionIndex: Int?

    var body: some View {
        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
            rowSlot(for: item, at: index)
        }
    }

    /// Each iteration of `ForEach` produces a single list row whose drop
    /// destination spans both the (optional) drop-slot skeleton and the row
    /// itself. Wrapping them together is what keeps the cursor inside the
    /// row's drop target after the skeleton has expanded — without this, the
    /// inserted skeleton pushes the row away, the cursor "leaves" the row's
    /// frame, `isTargeted` flips to `false`, the skeleton retracts, and the
    /// drop target enters a flicker loop that never accepts a drop.
    @ViewBuilder
    private func rowSlot(for item: PinnedItem, at index: Int) -> some View {
        VStack(spacing: 0) {
            if dropInsertionIndex == index {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            PinnedRowView(
                item: item,
                isSelected: sidebarSelection == .pinnedItem(item.id),
                onUnpin: { store.unpin(id: item.id) }
            )
        }
        .tag(SidebarSelection.pinnedItem(item.id))
        .onDrag(
            {
                PinnedItemTransfer(
                    item: item,
                    originScopeID: PinnedItemTransfer.pinnedSidebarScopeID
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: item)
            }
        )
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
    @ObservedObject private var dragPreviewState = PinnedDragPreviewState.shared
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if isTargeted {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            Color.clear
                .frame(height: 12)
        }
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
    }
}

/// Full row-shaped placeholder rendered at the prospective drop slot while a
/// pin drag is in progress. Displays a faded copy of the dragged item using
/// ``PinnedRowView``'s layout so the skeleton matches the live row, wrapped in
/// a dotted accent outline. Falls back to a content-less wireframe if the
/// active dragged item has not been published (first frame of the drag, or
/// macOS dropping the preview view tree before publication).
struct PinnedDropSkeletonRow: View {
    let item: PinnedItem?

    var body: some View {
        ZStack {
            if let item {
                PinnedRowView(
                    item: item,
                    isSelected: false,
                    onUnpin: {}
                )
                .opacity(0.45)
            } else {
                Color.clear
                    .frame(height: 56)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(
                    SpotiglassDesign.controlAccent.opacity(0.85),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [0.1, 5]
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
