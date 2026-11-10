import SwiftUI

struct PlaylistListRow: View {
    let playlist: PlaylistRowViewModel
    /// Signed-in Spotify user id; hides owner subtitle on the user's own playlists.
    var currentUserSpotifyID: String?
    var isActive: Bool = false
    var isPlaying: Bool = false
    /// Sidebar list row is the current `List` selection (drives heart vs heart.fill for Liked Songs).
    var isListSelected: Bool = false
    /// Source-side indicator: this row is also pinned in the pinned area.
    var isPinned: Bool = false
    /// Optional inline title editor supplied by the playlist sidebar.
    var titleOverride: AnyView? = nil

    private var isLikedSongsRow: Bool {
        playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    private let artworkSize = SpotiglassDesign.Layout.sidebarRowArtworkSize
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("PlaylistListRow:\(playlist.id)")
        #endif
        SidebarRow(subtitle: playlist.ownerTracksLine(currentUserID: currentUserSpotifyID, locale: spotiglassLocale)) {
            if isLikedSongsRow {
                LikedSongsArtwork(size: artworkSize, isEmphasized: isListSelected, cornerRadius: SpotiglassDesign.cornerXS)
            } else {
                // The cover the Music app shows, Apple's generated ones included; the placeholder
                // only when there is no artwork at all (#477).
                ArtworkView(url: playlist.artworkURL, size: artworkSize, cornerRadius: SpotiglassDesign.cornerXS)
            }
        } title: {
            if let titleOverride {
                titleOverride
            } else {
                Text(playlist.localizedTitle(locale: spotiglassLocale))
            }
        } accessory: {
            SidebarRowStatus(isPinned: isPinned, isNowPlaying: isActive, isPlaying: isPlaying)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            PlaylistOwnerDisplay.accessibilityLabel(
                title: playlist.localizedTitle(locale: spotiglassLocale),
                ownerName: playlist.localizedOwner(locale: spotiglassLocale),
                ownerID: playlist.ownerID,
                trackCountText: playlist.localizedTrackCountText(locale: spotiglassLocale),
                currentUserID: currentUserSpotifyID,
                nowPlaying: isActive
                    ? SpotiglassL10n.string("browser.playlistRow.nowPlaying", locale: spotiglassLocale)
                    : "",
                pinned: isPinned
                    ? SpotiglassL10n.string("browser.playlistRow.pinned", locale: spotiglassLocale)
                    : "",
                locale: spotiglassLocale
            )
        )
    }
}

extension String {
    /// A blank line instead of an empty one, so a subtitle that is still loading keeps its height.
    var nonEmptyLine: String { isEmpty ? " " : self }
}
