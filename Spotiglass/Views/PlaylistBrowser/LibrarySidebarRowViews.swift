import SwiftUI

struct LibraryHomeSidebarRow: View {
    var body: some View {
        Label(SpotiglassL10n.string("browser.home"), systemImage: "house")
            .onDrag({
                LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken).itemProvider()
            })
    }
}

struct PinnedSidebarLibraryRow: View {
    let item: PinnedItem
    let isSelected: Bool
    @EnvironmentObject private var pinnedStore: PinnedItemsStore

    var body: some View {
        PinnedRowView(
            item: item,
            isSelected: isSelected,
            onUnpin: { pinnedStore.unpin(id: item.id) }
        )
        .draggable(
            PinnedItemTransfer(
                item: item,
                originScopeID: PinnedItemTransfer.pinnedSidebarScopeID
            ),
            preview: {
                PinnedItemDragPill(item: item)
            }
        )
        .dragConfiguration(
            DragConfiguration(
                operationsWithinApp: .init(allowMove: false, allowDelete: true),
                operationsOutsideApp: .init(allowMove: false, allowDelete: false)
            )
        )
        .onDragSessionUpdated { session in
            guard case let .ended(operation) = session.phase else { return }
            guard operation == .delete || operation == .cancel || operation == .forbidden else { return }
            Task { @MainActor in
                pinnedStore.unpin(id: item.id)
                PinnedDragPreviewState.shared.endDrag()
            }
        }
        .contextMenu {
            Button(SpotiglassL10n.string("browser.unpin.short")) { pinnedStore.unpin(id: item.id) }
        }
    }
}
