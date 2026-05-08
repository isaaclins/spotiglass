import SwiftUI

struct PlaylistListRow: View {
    let playlist: PlaylistRowViewModel
    var isActive: Bool = false
    var isPlaying: Bool = false
    /// Sidebar list row is the current `List` selection (drives heart vs heart.fill for Liked Songs).
    var isListSelected: Bool = false
    /// Source-side indicator: this row is also pinned in the pinned area.
    var isPinned: Bool = false

    private var isLikedSongsRow: Bool {
        playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    private let artworkSize: CGFloat = 46

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
                                .foregroundStyle(isListSelected ? SpotiglassDesign.controlAccent : .secondary)
                                .symbolRenderingMode(.monochrome)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
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
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(2)
                        .accessibilityLabel("Pinned to sidebar")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(playlist.owner) • \(playlist.trackCountText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.title), by \(playlist.owner), \(playlist.trackCountText)\(isActive ? ", now playing" : "")\(isPinned ? ", pinned" : "")")
    }
}
