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
    /// The playlist has no name and ``title`` is the stand-in from when the row was built.
    let isUnnamed: Bool

    var isAlbumDetail: Bool {
        snapshotID.hasPrefix("album-")
    }

    init(_ playlist: MusicPlaylistSummary) {
        self.id = playlist.id
        self.title = playlist.name
        self.owner = playlist.ownerName
        self.ownerID = playlist.ownerID
        self.trackCount = playlist.trackCount
        if let trackCount = playlist.trackCount {
            self.trackCountText = SpotiglassL10n.format("browser.trackCount", Int64(trackCount))
        } else if playlist.snapshotID == AppleMusicItemMapping.playlistSnapshotID {
            self.trackCountText = ""
        } else {
            self.trackCountText = SpotiglassL10n.string("browser.trackCountUnavailable")
        }
        self.artworkURL = playlist.imageURL
        self.snapshotID = playlist.snapshotID
        self.isUnnamed = playlist.isUnnamed
    }

    /// Rows outlive a language switch, so a stand-in name is resolved when the row renders,
    /// like the Liked Songs title (#547).
    func localizedTitle(locale: Locale = SpotiglassL10n.locale) -> String {
        guard id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID else {
            if isUnnamed {
                return UnnamedMusicItem.playlist.placeholder(locale: locale)
            }
            return isAlbumDetail ? UnnamedMusicItem.displayName(title, kind: .album, locale: locale) : title
        }
        return SpotiglassL10n.string("browser.likedSongs.title", locale: locale)
    }

    /// The signed-in user's profile name is raw data. An empty name is the
    /// virtual Liked Songs row's fallback, which must be resolved at render
    /// time so an in-app language switch updates cached rows too.
    func localizedOwner(locale: Locale = SpotiglassL10n.locale) -> String {
        guard id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return AppleMusicItemMapping.localizedOwnerName(owner, ownerID: ownerID, locale: locale) }
        return SpotiglassL10n.string("browser.likedSongs.owner.you", locale: locale)
    }

    func localizedTrackCountText(locale: Locale = SpotiglassL10n.locale) -> String {
        let translated: String
        if id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID, trackCount == nil {
            translated = SpotiglassL10n.string("browser.likedSongs.savedTracks", locale: locale)
        } else if let trackCount {
            translated = SpotiglassL10n.format("browser.trackCount", locale: locale, Int64(trackCount))
        } else if snapshotID == AppleMusicItemMapping.playlistSnapshotID {
            // Apple Music lists library playlists without their tracks and the count arrives a
            // moment later; until then, or if it never does, the row says nothing rather than
            // calling every playlist broken (#407).
            translated = ""
        } else {
            translated = SpotiglassL10n.string("browser.trackCountUnavailable", locale: locale)
        }
        // Keep the legacy cached property useful to callers while preferring
        // the explicitly requested locale after a language switch.
        return trackCountText == translated ? trackCountText : translated
    }

    func ownerTracksLine(currentUserID: String?, locale: Locale = SpotiglassL10n.locale) -> String {
        PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: localizedOwner(locale: locale),
            ownerID: ownerID,
            trackCountText: localizedTrackCountText(locale: locale),
            currentUserID: currentUserID,
            locale: locale
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
        self.isUnnamed = false
    }

    /// Virtual Liked Songs row that retains the raw profile name. `nil` uses
    /// the locale-aware fallback owner at render time.
    init(likedSongsOwnerName: String?, totalTrackCount: Int?, artworkURL: URL?) {
        self.init(
            likedSongsOwnerDisplay: likedSongsOwnerName ?? "",
            totalTrackCount: totalTrackCount,
            artworkURL: artworkURL
        )
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
        self.isUnnamed = false
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
