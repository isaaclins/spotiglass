import SwiftUI

struct LibraryHomeSidebarRow: View {
    var body: some View {
        Label {
            L10nText("browser.home")
        } icon: {
            Image(systemName: "house")
        }
    }
}

struct PinnedSidebarLibraryRow: View {
    let item: PinnedItem
    let isSelected: Bool
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    var body: some View {
        PinnedRowView(
            item: item,
            isSelected: isSelected,
            onUnpin: { pinnedStore.unpin(id: item.id) }
        )
        .contextMenu {
            Button(SpotiglassL10n.string("browser.unpin.short", locale: spotiglassLocale)) { pinnedStore.unpin(id: item.id) }
        }
    }
}
