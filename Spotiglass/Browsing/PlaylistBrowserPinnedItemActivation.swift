import Foundation

/// Pinned-sidebar activation routing extracted from ``PlaylistBrowserView`` for unit testing.
enum PlaylistBrowserPinnedItemActivation {
    enum Route: Equatable {
        case staleRevert(selection: SidebarSelection?)
        case selectPlaylist(MusicPlaylistSummary)
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
            guard let summary = item.playlistSummary else { return nil }
            return .selectPlaylist(summary)
        case .artist:
            guard let spotifyID = item.spotifyID else { return nil }
            // What the pin shows, so a nameless item opens in the app's language (#547).
            return .selectArtist(id: spotifyID, displayName: item.localizedTitle())
        case .album:
            guard let spotifyID = item.spotifyID else { return nil }
            return .selectAlbum(
                id: spotifyID,
                title: item.localizedTitle(),
                // As saved, or the marker for "Album": the album page says it when it is shown, in
                // the language of the moment, and names a nameless artist the same way (#571).
                subtitle: item.subtitleKey == AlbumLine.yearlessKey ? AlbumLine.yearlessMarker : item.subtitle,
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
