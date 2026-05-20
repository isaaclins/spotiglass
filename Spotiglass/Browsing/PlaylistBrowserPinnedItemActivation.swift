import Foundation

/// Pinned-sidebar activation routing extracted from ``PlaylistBrowserView`` for unit testing.
enum PlaylistBrowserPinnedItemActivation {
    enum Route: Equatable {
        case staleRevert(selection: SidebarSelection?)
        case selectPlaylist(String)
        case selectArtist(id: String, displayName: String?)
        case selectAlbum(id: String, title: String, subtitle: String, artworkURL: URL?)
        case likedSongs
        case playTrack(uri: String, revertSelection: SidebarSelection?)
    }

    static func route(
        for item: PinnedItem,
        previousSelection: SidebarSelection?
    ) -> Route? {
        if item.isStale {
            return .staleRevert(selection: previousSelection)
        }
        switch item.kind {
        case .playlist:
            guard let spotifyID = item.spotifyID else { return nil }
            return .selectPlaylist(spotifyID)
        case .artist:
            guard let spotifyID = item.spotifyID else { return nil }
            return .selectArtist(id: spotifyID, displayName: item.title)
        case .album:
            guard let spotifyID = item.spotifyID else { return nil }
            return .selectAlbum(
                id: spotifyID,
                title: item.title,
                subtitle: item.subtitle,
                artworkURL: item.artworkURL
            )
        case .likedSongs:
            return .likedSongs
        case .track:
            guard let uri = item.spotifyURI else { return nil }
            return .playTrack(uri: uri, revertSelection: previousSelection)
        }
    }

    static func sidebarSelectionAfterActivation(
        item: PinnedItem,
        detailState: BrowsingLoadState<BrowsingDetailContent>
    ) -> SidebarSelection? {
        guard item.kind == .artist || item.kind == .album else { return nil }
        guard !PlaylistBrowserPinnedSidebarPolicy.itemShouldBeMarkedStale(for: detailState) else {
            return nil
        }
        return .pinnedItem(item.id)
    }
}
