import AppKit
import MusicKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    /// The item's pin ID, for Apple Music library covers saved with an expired URL.
    var artworkKey: String? = nil
    var cornerRadius: CGFloat = SpotiglassDesign.cornerS
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
        // Square: the artwork view around it clips it to its own corner radius.
        Rectangle()
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
                // A reused row that shows another cover gets a fresh, empty cover layer, so a
                // drag can't copy the previous cover before MusicKit draws the new one.
                .id(url)
                .background(OnScreenArtworkMarker(url: url, itemKey: itemKey))
        }
    }
}

/// Library covers on screen right now, so a drag preview can show one (#449). MusicKit draws
/// library artwork only inside a window: `ImageRenderer`, and with it the image macOS takes for
/// a drag, gets blank pixels even after the same cover was drawn. In the window the cover is an
/// image layer MusicKit has filled, so the preview takes that image when the drag begins.
@MainActor
final class OnScreenArtwork {
    static let shared = OnScreenArtwork()

    /// Marker views by cover URL and by pin ID. Weak: a row that goes away drops out by itself.
    private var viewsByKey: [String: NSHashTable<OnScreenArtworkMarker.MarkerView>] = [:]
    /// Size at which the table is tidied next. Doubles with what stays after tidying, so a
    /// screen that keeps many covers alive doesn't tidy on every new cover.
    private var tidyAt = 1_000

    func register(_ view: OnScreenArtworkMarker.MarkerView) {
        // Keys of covers that were freed without leaving their window first.
        if viewsByKey.count > tidyAt {
            viewsByKey = viewsByKey.filter { key, views in views.allObjects.contains { $0.keys.contains(key) } }
            tidyAt = max(1_000, viewsByKey.count * 2)
        }
        for key in view.keys {
            let views = viewsByKey[key] ?? .weakObjects()
            views.add(view)
            viewsByKey[key] = views
        }
    }

    /// A marker that left its window, or a reused row's marker that now shows another cover, no
    /// longer answers for `keys`.
    func unregister(_ view: OnScreenArtworkMarker.MarkerView, keys: [String]) {
        for key in keys {
            guard let views = viewsByKey[key] else { continue }
            views.remove(view)
            if views.allObjects.isEmpty { viewsByKey[key] = nil }
        }
    }

    /// The cover for `url` (or the pin `itemKey`) as MusicKit drew it on screen, or nil when no
    /// view shows it drawn. A pin keeps last session's library URL, so the pin ID finds it too.
    func snapshot(url: URL?, itemKey: String? = nil) -> NSImage? {
        for key in OnScreenArtworkMarker.keys(url: url, itemKey: itemKey) {
            guard let views = viewsByKey[key] else { continue }
            // The sharpest copy first: a header's cover over a command palette thumbnail.
            let showing = views.allObjects.filter { $0.keys.contains(key) }
                .sorted { $0.drawnPixelWidth > $1.drawnPixelWidth }
            for view in showing {
                if let image = view.drawnCover() { return image }
            }
            if views.allObjects.isEmpty { viewsByKey[key] = nil }
        }
        return nil
    }
}

/// Sits behind a MusicKit cover and registers where it is drawn with ``OnScreenArtwork``.
struct OnScreenArtworkMarker: NSViewRepresentable {
    let url: URL
    var itemKey: String?

    static func keys(url: URL?, itemKey: String?) -> [String] {
        [url.map { "url:" + $0.absoluteString }, itemKey.map { "item:" + $0 }].compactMap { $0 }
    }

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.keys = Self.keys(url: url, itemKey: itemKey)
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        let keys = Self.keys(url: url, itemKey: itemKey)
        guard view.keys != keys else { return }
        OnScreenArtwork.shared.unregister(view, keys: view.keys)
        view.keys = keys
        if view.window != nil { OnScreenArtwork.shared.register(view) }
    }

    final class MarkerView: NSView {
        var keys: [String] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                OnScreenArtwork.shared.register(self)
            } else {
                OnScreenArtwork.shared.unregister(self, keys: keys)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The cover MusicKit drew in front of this view: the image layer that covers exactly
        /// this view's frame, drawn on its own. Drawing that one layer, not a picture of the
        /// window, leaves out whatever is around or over the cover (the row's background, a pin
        /// badge). Only layers in front of this view count: it is the cover's background, so
        /// the placeholder behind it is never taken. Before MusicKit has drawn the cover its
        /// layer is empty, and there is no cover to take yet; the search stops at the first
        /// layer with this frame, so a same-sized layer over an empty cover isn't taken either.
        /// It looks only at the first level where anything is in front of this view (where the
        /// cover is), not further out among the row's own layers such as its border.
        func drawnCover() -> NSImage? {
            guard window != nil, !visibleRect.isEmpty, let marker = layer else { return nil }
            var branch = marker
            for _ in 0..<4 {
                guard let container = branch.superlayer else { break }
                let layers = container.sublayers ?? []
                if let index = layers.firstIndex(where: { $0 === branch }), index + 1 < layers.count {
                    for layer in layers[(index + 1)...] {
                        if let cover = coverLayer(layer, over: marker, depth: 3) { return drawn(cover) }
                    }
                    return nil
                }
                branch = container
            }
            return nil
        }

        /// `layer` or the first layer inside it, back to front, with contents and exactly the
        /// marker's frame.
        private func coverLayer(_ layer: CALayer, over marker: CALayer, depth: Int) -> CALayer? {
            let frame = layer.convert(layer.bounds, to: marker)
            let bounds = marker.bounds
            let hasMarkersFrame = abs(frame.minX - bounds.minX) <= 1 && abs(frame.minY - bounds.minY) <= 1
                && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
            // A layer with that frame and nothing inside is the cover before MusicKit filled it:
            // it counts as found (and draws nothing), so a layer further in front isn't taken.
            if hasMarkersFrame, layer.contents != nil || (layer.sublayers ?? []).isEmpty {
                return layer
            }
            guard depth > 0 else { return nil }
            for sublayer in layer.sublayers ?? [] {
                if let cover = coverLayer(sublayer, over: marker, depth: depth - 1) { return cover }
            }
            return nil
        }

        /// How many pixels wide this cover is drawn on its screen.
        var drawnPixelWidth: CGFloat { bounds.width * (window?.backingScaleFactor ?? 1) }

        /// `layer` drawn on its own at this screen's scale, or nil when it isn't an opaque cover
        /// (nothing drawn yet, or only a thin outline).
        private func drawn(_ layer: CALayer) -> NSImage? {
            let scale = window?.backingScaleFactor ?? 2
            let width = max(1, Int((layer.bounds.width * scale).rounded()))
            let height = max(1, Int((layer.bounds.height * scale).rounded()))
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
            context.scaleBy(x: CGFloat(width) / layer.bounds.width, y: CGFloat(height) / layer.bounds.height)
            // SwiftUI's layers are flipped, the bitmap is not: draw the cover the right way up.
            if layer.contentsAreFlipped() {
                context.translateBy(x: 0, y: layer.bounds.height)
                context.scaleBy(x: 1, y: -1)
            }
            context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
            layer.render(in: context)
            // Covers are opaque: at least half of an 8 x 8 grid must be.
            let samples = 8
            let opaque = (0..<samples * samples).filter { i in
                let x = (i % samples * 2 + 1) * width / (samples * 2)
                let y = (i / samples * 2 + 1) * height / (samples * 2)
                return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }.count
            guard opaque * 2 >= samples * samples else { return nil }
            let image = NSImage(size: layer.bounds.size)
            image.addRepresentation(rep)
            return image
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
