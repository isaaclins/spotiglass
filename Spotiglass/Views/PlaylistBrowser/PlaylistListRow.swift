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

    private let artworkSize: CGFloat = 46
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Group {
                if isLikedSongsRow {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .fill(.secondary.opacity(0.16))
                        .frame(width: artworkSize, height: artworkSize)
                        .overlay {
                            Image(systemName: isListSelected ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(
                                    isListSelected
                                        ? AnyShapeStyle(SpotiglassAccentStyle())
                                        : AnyShapeStyle(.secondary)
                                )
                                .symbolRenderingMode(.monochrome)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
                        }
                } else {
                    ArtworkView(url: playlist.artworkURL, size: artworkSize)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    PlayingWaveformIcon(isPlaying: isPlaying)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                        )
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                        .padding(3)
                        .background(
                            Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                        )
                        .padding(2)
                        .help(SpotiglassL10n.string("browser.pinned"))
                        .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let titleOverride {
                    titleOverride
                } else {
                    Text(playlist.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                Text(playlist.ownerTracksLine(currentUserID: currentUserSpotifyID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            PlaylistOwnerDisplay.accessibilityLabel(
                title: playlist.title,
                ownerName: playlist.owner,
                ownerID: playlist.ownerID,
                trackCountText: playlist.trackCountText,
                currentUserID: currentUserSpotifyID,
                nowPlaying: isActive ? SpotiglassL10n.string("browser.playlistRow.nowPlaying") : "",
                pinned: isPinned ? SpotiglassL10n.string("browser.playlistRow.pinned") : ""
            )
        )
    }
}
