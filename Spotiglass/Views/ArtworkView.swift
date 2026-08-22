import AppKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let url {
                CachedArtworkImage(url: url, size: size)
            } else {
                ArtworkPlaceholderContent(state: .none, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
        }
    }
}

/// Why artwork is not on screen. All three used to draw the identical static
/// glyph, so a cover that was still downloading, one whose fetch had failed and
/// an album that simply has no cover were indistinguishable, and a failure
/// looked like a permanent absence (#146).
enum ArtworkPlaceholderState: Equatable {
    /// No artwork URL exists for this item.
    case none
    case loading
    case failed

    var systemImage: String {
        switch self {
        case .none: "music.note"
        case .loading: "music.note"
        case .failed: "arrow.clockwise"
        }
    }

    var helpKey: String {
        switch self {
        case .none: "artwork.state.none"
        case .loading: "artwork.state.loading"
        case .failed: "artwork.state.failed"
        }
    }
}

struct ArtworkPlaceholderContent: View {
    let state: ArtworkPlaceholderState
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Below this the artwork is a thumbnail in a dense list, where a spinner is
    /// noise rather than information; the glyph alone carries the state there.
    private static let progressIndicatorMinimumSize: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .overlay {
                if state == .loading, size >= Self.progressIndicatorMinimumSize, !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: state.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
            .help(SpotiglassL10n.string(state.helpKey))
            .accessibilityLabel(SpotiglassL10n.string(state.helpKey))
    }
}

private struct CachedArtworkImage: View {
    let url: URL
    let size: CGFloat
    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Group {
            if let image = artworkLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkPlaceholderContent(
                    state: artworkLoader.didFail ? .failed : .loading,
                    size: size
                )
            }
        }
        .task(id: url.absoluteString) {
            // Re-entering this state resets the failure, so scrolling a row back
            // into view retries rather than leaving a permanent hole.
            await artworkLoader.load(for: url)
        }
    }
}
