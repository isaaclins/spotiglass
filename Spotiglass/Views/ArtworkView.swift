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
                .background(OnScreenArtworkMarker(url: url, itemKey: itemKey))
        }
    }
}

/// Library covers on screen right now, so a drag preview can show one (#449). MusicKit draws
/// library artwork only inside a window: `ImageRenderer`, and with it the image macOS takes for
/// a drag, gets blank pixels even after the same cover was drawn. A snapshot of the window
/// where a cover already shows has it, so the preview takes the cover from there when the drag
/// begins.
@MainActor
final class OnScreenArtwork {
    static let shared = OnScreenArtwork()

    /// Marker views by cover URL and by pin ID. Weak: a row that goes away drops out by itself.
    private var viewsByKey: [String: NSHashTable<OnScreenArtworkMarker.MarkerView>] = [:]

    func register(_ view: OnScreenArtworkMarker.MarkerView) {
        // Scrolling a large library registers thousands of covers; drop the ones that are gone.
        if viewsByKey.count > 1_000 {
            viewsByKey = viewsByKey.filter { !$0.value.allObjects.isEmpty }
        }
        for key in view.keys {
            let views = viewsByKey[key] ?? .weakObjects()
            views.add(view)
            viewsByKey[key] = views
        }
    }

    /// The cover for `url` (or the pin `itemKey`) as it shows on screen, or nil when no view
    /// shows it. A pin keeps last session's library URL, so the pin ID finds it too.
    func snapshot(url: URL?, itemKey: String? = nil) -> NSImage? {
        for key in OnScreenArtworkMarker.keys(url: url, itemKey: itemKey) {
            guard let views = viewsByKey[key] else { continue }
            for view in views.allObjects where view.keys.contains(key) {
                if let image = view.snapshot() { return image }
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
        view.keys = keys
        if view.window != nil { OnScreenArtwork.shared.register(view) }
    }

    final class MarkerView: NSView {
        var keys: [String] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { OnScreenArtwork.shared.register(self) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// What is drawn over this view's frame: the cover in front of it.
        ///
        /// Asks the nearest enclosing view that draws anything there, not the window's root: the
        /// sidebar sits in a glass view with its own layers, and the root draws nothing over it,
        /// so sidebar covers came back as an empty tile. When that view draws something that
        /// isn't a cover (MusicKit hasn't drawn it yet, so the see-through placeholder shows),
        /// there is no cover to take; looking further out would only find the row's or window's
        /// background.
        func snapshot() -> NSImage? {
            guard window != nil, !visibleRect.isEmpty else { return nil }
            var ancestor = superview
            while let view = ancestor {
                let cover = convert(bounds, to: view).integral
                guard cover.width >= 1, cover.height >= 1, view.bounds.contains(cover) else { return nil }
                // A thin ring around the cover shows what is behind it.
                let ringed = cover.insetBy(dx: -Self.ringWidth, dy: -Self.ringWidth)
                let rect = view.bounds.contains(ringed) ? ringed : cover
                guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
                view.cacheDisplay(in: rect, to: rep)
                let drawn = DrawnCover(rep: rep, ring: (rect.width - cover.width) / 2 / rect.width)
                switch drawn.coverage() {
                case .nothing:
                    ancestor = view.superview
                case .cover:
                    return drawn.image(size: cover.size)
                case .notACover:
                    return nil
                }
            }
            return nil
        }

        private static let ringWidth: CGFloat = 2
    }
}

/// A snapshot of a cover's frame, with an optional ring of what is around it.
private struct DrawnCover {
    enum Coverage { case nothing, cover, notACover }

    let rep: NSBitmapImageRep
    /// Ring width as a share of the snapshot's width (0 when there is no ring).
    let ring: CGFloat
    private static let samples = 8

    /// A drawn cover is opaque over at least half of an 8 x 8 grid (a round artist cover fills
    /// about 80% of its square); a blank view is clear everywhere. Over a solid background the
    /// see-through placeholder is opaque too, but its edge is that background with a faint
    /// tint, so a cover whose edge matches what is around it is not taken.
    func coverage() -> Coverage {
        let n = Self.samples
        var drawn = 0
        var opaque = 0
        var edge: [SIMD4<Double>] = []
        for row in 0..<n {
            for column in 0..<n {
                let color = sample(Double(column * 2 + 1) / Double(n * 2), Double(row * 2 + 1) / Double(n * 2))
                if color.w > 0.02 { drawn += 1 }
                if color.w > 0.9 { opaque += 1 }
                if row == 0 || row == n - 1 || column == 0 || column == n - 1 { edge.append(color) }
            }
        }
        if drawn == 0 { return .nothing }
        guard opaque * 2 >= n * n else { return .notACover }
        guard ring > 0 else { return .cover }
        let around = Self.median(ringSamples())
        let matching = edge.filter { Self.distance($0, around) < 0.15 }.count
        return matching * 10 >= edge.count * 9 ? .notACover : .cover
    }

    /// The cover without the ring.
    func image(size: CGSize) -> NSImage? {
        let inset = ring * CGFloat(rep.pixelsWide)
        let crop = CGRect(
            x: inset, y: inset,
            width: CGFloat(rep.pixelsWide) - 2 * inset, height: CGFloat(rep.pixelsHigh) - 2 * inset
        ).integral
        guard let cgImage = rep.cgImage?.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Color at (`u`, `v`) inside the cover, both from 0 to 1, as premultiplied RGBA.
    private func sample(_ u: Double, _ v: Double) -> SIMD4<Double> {
        let r = Double(ring)
        return pixel(r + u * (1 - 2 * r), r + v * (1 - 2 * r))
    }

    /// The middle of the ring on all four sides.
    private func ringSamples() -> [SIMD4<Double>] {
        let middle = Double(ring) / 2
        return (0..<Self.samples).flatMap { i -> [SIMD4<Double>] in
            let t = Double(i * 2 + 1) / Double(Self.samples * 2)
            return [pixel(t, middle), pixel(t, 1 - middle), pixel(middle, t), pixel(1 - middle, t)]
        }
    }

    private func pixel(_ u: Double, _ v: Double) -> SIMD4<Double> {
        let x = min(rep.pixelsWide - 1, Int(u * Double(rep.pixelsWide)))
        let y = min(rep.pixelsHigh - 1, Int(v * Double(rep.pixelsHigh)))
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return .zero }
        let a = Double(color.alphaComponent)
        return SIMD4(Double(color.redComponent) * a, Double(color.greenComponent) * a, Double(color.blueComponent) * a, a)
    }

    private static func median(_ colors: [SIMD4<Double>]) -> SIMD4<Double> {
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return SIMD4(mid(colors.map(\.x)), mid(colors.map(\.y)), mid(colors.map(\.z)), mid(colors.map(\.w)))
    }

    private static func distance(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double {
        max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z), abs(a.w - b.w))
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
