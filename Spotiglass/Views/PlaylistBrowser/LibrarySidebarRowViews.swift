import SwiftUI

struct LibraryHomeSidebarRow: View {
    var body: some View {
        Label(SpotiglassL10n.string("browser.home"), systemImage: "house")
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
        .contextMenu {
            Button(SpotiglassL10n.string("browser.unpin.short")) { pinnedStore.unpin(id: item.id) }
        }
    }
}
