import Foundation

struct PlaylistRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let owner: String
    let trackCountText: String
    let artworkURL: URL?
    let snapshotID: String

    init(_ playlist: SpotifyPlaylistSummary) {
        self.id = playlist.id
        self.title = playlist.name
        self.owner = playlist.ownerName
        self.trackCountText = playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks"
        self.artworkURL = playlist.imageURL
        self.snapshotID = playlist.snapshotID
    }

    /// Virtual library row for Liked Songs (sidebar and detail header). Pass `totalTrackCount: nil` for the sidebar before counts are known (`trackCountText` becomes “Saved tracks”).
    init(likedSongsOwnerDisplay: String, totalTrackCount: Int?, artworkURL: URL?) {
        self.id = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        self.title = "Liked Songs"
        self.owner = likedSongsOwnerDisplay
        if let totalTrackCount {
            self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
        } else {
            self.trackCountText = "Saved tracks"
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
        self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
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
}
