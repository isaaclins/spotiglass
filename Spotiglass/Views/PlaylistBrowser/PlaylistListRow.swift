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
        HStack(spacing: SpotiglassDesign.spacingS) {
            Group {
                if isLikedSongsRow {
                    LikedSongsArtwork(size: artworkSize, isEmphasized: isListSelected)
                } else {
                    ArtworkView(url: playlist.artworkURL, size: artworkSize)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    PlayingArtworkBadge(isPlaying: isPlaying)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    PinnedBadge(scale: .compact)
                }
            }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXXS) {
                if let titleOverride {
                    titleOverride
                } else {
                    Text(playlist.localizedTitle(locale: spotiglassLocale))
                        .font(.headline)
                        .lineLimit(1)
                }

                // A count still loading (or unknown) leaves the line blank but keeps its height,
                // so rows don't jump when the count arrives.
                Text(playlist.ownerTracksLine(
                    currentUserID: currentUserSpotifyID,
                    locale: spotiglassLocale
                ).nonEmptyLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXXS)
        .contentShape(Rectangle())
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
