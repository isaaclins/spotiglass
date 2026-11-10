import SwiftUI

/// A whole playlist, album or artist shown as a tile, card or row. Every place that shows one
/// builds its right-click menu from here, so a Home tile, a search card and the sidebar row of
/// the same playlist offer the same entries in the same order (#478).
enum CollectionMenuTarget: Equatable {
    case playlist(MusicPlaylistSummary)
    /// An album or artist: the pin it makes is all its menu needs.
    case pinnable(PinnedItem)

    var pinnedItem: PinnedItem {
        switch self {
        case let .playlist(summary): .playlist(summary)
        case let .pinnable(item): item
        }
    }
}

enum CollectionMenuEntry: Equatable {
    case editPlaylistName
    case deletePlaylist
    case pin
    case unpin
}

/// The entries of one collection's menu, in groups a divider separates.
struct CollectionMenu: Equatable {
    /// Inside the sidebar "Unpin" says enough; everywhere else it names the sidebar.
    enum Placement {
        case sidebar
        case content
    }

    let sections: [[CollectionMenuEntry]]

    var entries: [CollectionMenuEntry] { sections.flatMap { $0 } }

    static func menu(
        for target: CollectionMenuTarget,
        isPinned: Bool,
        canRename: Bool,
        canDelete: Bool
    ) -> CollectionMenu {
        let pinSection: [CollectionMenuEntry] = [isPinned ? .unpin : .pin]
        guard case .playlist = target, canRename else {
            return CollectionMenu(sections: [pinSection])
        }
        // Delete only shows for a playlist the user may also rename, as in the sidebar.
        let editSection: [CollectionMenuEntry] = canDelete ? [.editPlaylistName, .deletePlaylist] : [.editPlaylistName]
        return CollectionMenu(sections: [editSection, pinSection])
    }

    static func title(for entry: CollectionMenuEntry, placement: Placement) -> String {
        switch entry {
        case .editPlaylistName: SpotiglassL10n.string("browser.editPlaylistName")
        case .deletePlaylist: SpotiglassL10n.string("browser.deletePlaylist")
        case .pin: SpotiglassL10n.string("browser.pin")
        case .unpin: SpotiglassL10n.string(placement == .sidebar ? "browser.unpin.short" : "browser.unpin")
        }
    }
}

/// The menu's buttons. The same list backs the right-click menu and the VoiceOver actions.
struct CollectionMenuItems: View {
    let menu: CollectionMenu
    let placement: CollectionMenu.Placement
    let perform: (CollectionMenuEntry) -> Void

    var body: some View {
        ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 {
                Divider()
            }
            ForEach(section, id: \.self) { entry in
                Button(
                    CollectionMenu.title(for: entry, placement: placement),
                    role: entry == .deletePlaylist ? .destructive : nil
                ) {
                    perform(entry)
                }
            }
        }
    }
}

extension View {
    /// Right-click menu and VoiceOver actions for a playlist, album or artist shown outside the
    /// sidebar. `nil` (Liked Songs) adds neither: Liked Songs has no menu anywhere.
    /// A card whose actions belong on an inner button passes `includesAccessibilityActions: false`
    /// and puts ``collectionAccessibilityActions(_:browserViewModel:)`` on that button.
    func collectionContextMenu(
        _ target: CollectionMenuTarget?,
        browserViewModel: PlaylistBrowserViewModel,
        includesAccessibilityActions: Bool = true
    ) -> some View {
        modifier(CollectionContextMenuModifier(
            target: target,
            browserViewModel: browserViewModel,
            parts: includesAccessibilityActions ? [.menu, .accessibilityActions] : [.menu]
        ))
    }

    /// The menu's entries as VoiceOver actions only, without a right-click menu.
    func collectionAccessibilityActions(
        _ target: CollectionMenuTarget?,
        browserViewModel: PlaylistBrowserViewModel
    ) -> some View {
        modifier(CollectionContextMenuModifier(
            target: target,
            browserViewModel: browserViewModel,
            parts: [.accessibilityActions]
        ))
    }
}

struct CollectionContextMenuModifier: ViewModifier {
    struct Parts: OptionSet {
        let rawValue: Int
        static let menu = Parts(rawValue: 1 << 0)
        static let accessibilityActions = Parts(rawValue: 1 << 1)
    }

    let target: CollectionMenuTarget?
    let browserViewModel: PlaylistBrowserViewModel
    let parts: Parts

    @EnvironmentObject private var pinnedStore: PinnedItemsStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if let target {
            let menu = menu(for: target)
            content
                .modifier(OptionalContextMenu(isEnabled: parts.contains(.menu)) {
                    CollectionMenuItems(menu: menu, placement: .content) { perform($0, on: target) }
                })
                .accessibilityActions {
                    if parts.contains(.accessibilityActions) {
                        ForEach(menu.entries, id: \.self) { entry in
                            Button(CollectionMenu.title(for: entry, placement: .content)) {
                                perform(entry, on: target)
                            }
                        }
                    }
                }
        } else {
            content
        }
    }

    private func menu(for target: CollectionMenuTarget) -> CollectionMenu {
        var canRename = false
        var canDelete = false
        if case let .playlist(summary) = target {
            canRename = browserViewModel.canRenamePlaylist(summary)
            canDelete = browserViewModel.canDeletePlaylist(summary)
        }
        return CollectionMenu.menu(
            for: target,
            isPinned: pinnedStore.isPinned(id: target.pinnedItem.id),
            canRename: canRename,
            canDelete: canDelete
        )
    }

    func perform(_ entry: CollectionMenuEntry, on target: CollectionMenuTarget) {
        switch entry {
        case .editPlaylistName:
            guard case let .playlist(summary) = target else { return }
            Task { await browserViewModel.openPlaylistForNameEditing(summary) }
        case .deletePlaylist:
            guard case let .playlist(summary) = target else { return }
            browserViewModel.requestPlaylistDeletion(summary)
        case .pin:
            pinnedStore.pin(target.pinnedItem)
        case .unpin:
            pinnedStore.unpin(id: target.pinnedItem.id)
        }
    }
}

private struct OptionalContextMenu<MenuItems: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { menuItems() }
        } else {
            content
        }
    }
}
