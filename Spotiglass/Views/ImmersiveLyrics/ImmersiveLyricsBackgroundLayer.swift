import AppKit
import SwiftUI

struct ImmersiveLyricsBackgroundLayer: View {
    let reduceTransparency: Bool
    let albumArtURL: URL?

    var body: some View {
        Group {
            if reduceTransparency {
                Color.black
            } else {
                ZStack {
                    if let url = albumArtURL {
                        ImmersiveBlurredArtwork(url: url)
                    } else {
                        Color.black
                    }

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.5),
                            Color.black.opacity(0.78),
                            Color.black.opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }
}

// MARK: - Blurred album backdrop (bounded cost)

/// Full-bleed blurred artwork: small source bitmap + moderate blur radius, then scale to fill.
/// Cheaper than blurring a 1600pt tile at r≈36 (previous approach).
struct ImmersiveBlurredArtwork: View {
    let url: URL

    /// After optional downscale, this is the raster size SwiftUI blurs (not window size).
    private let blurredTileSize: CGFloat = 1_024
    private let blurRadius: CGFloat = 24
    @StateObject private var artworkLoader: ArtworkImageLoader

    init(url: URL, initialImage: NSImage? = nil) {
        self.url = url
        _artworkLoader = StateObject(
            wrappedValue: ArtworkImageLoader(
                initialImage: initialImage,
                initialURL: initialImage == nil ? nil : url,
                imageTransformer: { image in
                    Self.downscaledForBlur(image, maxEdge: 576)
                }
            )
        )
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let image = artworkLoader.image {
                    // Blur is computed on a fixed tile, then scaled up to **aspect-fill** the window.
                    // Without this, a ~1024pt tile centered in an ultrawide/tall window leaves black gutters;
                    // scaling mirrors “stretching” the artwork into the sides instead of empty black.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: blurredTileSize, height: blurredTileSize)
                        .compositingGroup()
                        .blur(radius: blurRadius)
                        .scaleEffect(Self.coverScaleForBlurredBackdrop(
                            tile: blurredTileSize,
                            blurRadius: blurRadius,
                            target: size
                        ))
                } else {
                    Color.black
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .task(id: url.absoluteString) {
            await artworkLoader.load(for: url)
        }
    }

    /// Minimum uniform scale so the blurred tile (plus fringe from `blurRadius`) covers `target` without letterboxing.
    // Internal so tests can verify the aspect-fill policy without relying on view inspection.
    static func coverScaleForBlurredBackdrop(tile: CGFloat, blurRadius: CGFloat, target: CGSize) -> CGFloat {
        let fringe = blurRadius * 2.5
        let eff = tile + fringe
        guard eff > 0, target.width > 0, target.height > 0 else { return 1 }
        let sx = target.width / eff
        let sy = target.height / eff
        return max(sx, sy, 1)
    }

    // Internal so tests can exercise both the pass-through and rasterization paths directly.
    static func downscaledForBlur(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let s = image.size
        let w = s.width
        let h = s.height
        guard w > 0, h > 0 else { return image }
        let maxSide = max(w, h)
        guard maxSide > maxEdge else { return image }
        let scale = maxEdge / maxSide
        let nw = max(1, floor(w * scale))
        let nh = max(1, floor(h * scale))
        let out = NSImage(size: NSSize(width: nw, height: nh))
        out.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .medium
        }
        image.draw(
            in: NSRect(x: 0, y: 0, width: nw, height: nh),
            from: NSRect(x: 0, y: 0, width: w, height: h),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }
}
