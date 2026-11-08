import AppKit
import MusicKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    /// The item's pin ID, for Apple Music library covers saved with an expired URL.
    var artworkKey: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let url {
                CachedArtworkImage(url: url, size: size, artworkKey: artworkKey)
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

/// Artwork renderer for artist entities. Artist portraits keep their circular
/// identity in detail headers while albums and playlists continue using
/// ``ArtworkView``'s rounded-square treatment (#231).
struct CircularArtworkView: View {
    let url: URL?
    let size: CGFloat
    var artworkKey: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let url {
                CachedArtworkImage(url: url, size: size, artworkKey: artworkKey)
            } else {
                ArtworkPlaceholderContent(state: .none, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
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
    /// `false` when real artwork is drawn on top of the placeholder: then the placeholder must not
    /// say "No artwork" in a tooltip or to VoiceOver while a cover is visible.
    var describesState = true
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
            .help(describesState ? SpotiglassL10n.string(state.helpKey) : "")
            .accessibilityLabel(describesState ? SpotiglassL10n.string(state.helpKey) : "")
            .accessibilityHidden(!describesState)
    }
}

/// Draws Apple Music library artwork (`musicKit://` URLs registered in
/// ``AppleMusicArtworkRegistry``) with MusicKit's own view. Draws nothing for any other URL, so
/// callers layer it over their placeholder.
struct MusicKitArtwork: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    /// A pin's ID: pins keep last session's URL, which MusicKit no longer knows.
    var itemKey: String? = nil

    var body: some View {
        if let url, AppleMusicArtworkRegistry.needsMusicKit(url),
            let artwork = AppleMusicArtworkRegistry.shared.artwork(for: url, itemKey: itemKey)
        {
            ArtworkImage(artwork, width: width, height: height)
        }
    }
}

/// The artwork URL to download for a cover drawn `points` wide on a `scale` screen. Apple Music
/// tracks are mapped with a row-sized URL, so without this a Home card or the Lyrics cover
/// stretched a 120 px image to 300 px and more (#426). Spotify URLs come back unchanged: they
/// already point at the largest image Spotify offers.
enum ArtworkRequest {
    static func url(
        _ url: URL,
        points: CGFloat,
        scale: CGFloat,
        itemKey: String? = nil,
        registry: AppleMusicArtworkRegistry = .shared
    ) -> URL {
        registry.sizedURL(
            for: url,
            itemKey: itemKey,
            pixelSize: AppleMusicArtworkRegistry.requestPixelSize(forDrawnPixels: points * max(scale, 1))
        )
    }
}

private struct CachedArtworkImage: View {
    let url: URL
    let size: CGFloat
    var artworkKey: String? = nil
    @StateObject private var artworkLoader = ArtworkImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if AppleMusicArtworkRegistry.needsMusicKit(url) {
            // Apple Music library artwork: only MusicKit can draw it.
            // MusicKit draws nothing for artwork it can't load (e.g. songs that only live in the
            // cloud library), so the placeholder underneath shows through.
            ZStack {
                ArtworkPlaceholderContent(state: .none, size: size, describesState: false)
                MusicKitArtwork(url: url, width: size, height: size, itemKey: artworkKey)
            }
        } else {
            downloadedArtwork
        }
    }

    private var downloadedArtwork: some View {
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
        .task(id: requestURL.absoluteString) {
            // Re-entering this state resets the failure, so scrolling a row back
            // into view retries rather than leaving a permanent hole.
            await artworkLoader.load(for: requestURL, artwork: url)
        }
    }

    private var requestURL: URL {
        ArtworkRequest.url(url, points: size, scale: displayScale, itemKey: artworkKey)
    }
}
