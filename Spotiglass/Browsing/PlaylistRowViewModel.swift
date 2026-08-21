import Foundation

struct PlaylistRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let owner: String
    /// Spotify user id for the playlist owner; empty for album rows where owner is artist text.
    let ownerID: String
    let trackCount: Int?
    let trackCountText: String
    let artworkURL: URL?
    let snapshotID: String

    init(_ playlist: SpotifyPlaylistSummary) {
        self.id = playlist.id
        self.title = playlist.name
        self.owner = playlist.ownerName
        self.ownerID = playlist.ownerID
        self.trackCount = playlist.trackCount
        if let trackCount = playlist.trackCount {
            self.trackCountText = SpotiglassL10n.format("browser.trackCount", Int64(trackCount))
        } else {
            self.trackCountText = SpotiglassL10n.string("browser.trackCountUnavailable")
        }
        self.artworkURL = playlist.imageURL
        self.snapshotID = playlist.snapshotID
    }

    func ownerTracksLine(currentUserID: String?) -> String {
        PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: owner,
            ownerID: ownerID,
            trackCountText: trackCountText,
            currentUserID: currentUserID
        )
    }

    /// Virtual library row for Liked Songs (sidebar and detail header). Pass `totalTrackCount: nil` for the sidebar before counts are known (`trackCountText` becomes “Saved tracks”).
    init(likedSongsOwnerDisplay: String, totalTrackCount: Int?, artworkURL: URL?) {
        self.id = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        self.title = SpotiglassL10n.string("browser.likedSongs.title")
        self.owner = likedSongsOwnerDisplay
        self.ownerID = ""
        self.trackCount = totalTrackCount
        if let totalTrackCount {
            self.trackCountText = SpotiglassL10n.format("browser.trackCount", Int64(totalTrackCount))
        } else {
            self.trackCountText = SpotiglassL10n.string("browser.likedSongs.savedTracks")
        }
        self.artworkURL = artworkURL
        self.snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID
    }

    /// Pinned-album header rendered through the existing playlist detail UI.
    /// `albumID` is used as the row id so playback's `activePlaylistID` and the
    /// click-source identification stay consistent with how the rest of the
    /// app keys "currently shown collection".
    init(albumDisplayName: String, artistsDisplay: String, totalTrackCount: Int, artworkURL: URL?, albumID: String) {
        self.id = albumID
        self.title = albumDisplayName
        self.owner = artistsDisplay
        self.ownerID = ""
        self.trackCount = totalTrackCount
        self.trackCountText = SpotiglassL10n.format("browser.trackCount", Int64(totalTrackCount))
        self.artworkURL = artworkURL
        self.snapshotID = "album-\(albumID)"
    }
}

struct PlaylistDetailViewModel: Equatable {
    let playlist: PlaylistRowViewModel
    let tracks: [TrackRowViewModel]
}

enum BrowsingDetailContent: Equatable {
    case playlist(PlaylistDetailViewModel)
    case artist(ArtistDetailViewModel)
    /// Home surface marker. The home feed renders from the dedicated
    /// `home*` published sections on ``PlaylistBrowserViewModel`` (each loads
    /// independently), so the content payload here is just a routing token.
    case home
    /// Catalog search surface marker. Results live on ``CatalogSearchViewModel``,
    /// so like ``home`` this payload is only a routing token.
    case search
}
