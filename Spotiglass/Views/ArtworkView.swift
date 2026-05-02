import AppKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                CachedArtworkImage(url: url)
            } else {
                ArtworkPlaceholderContent()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct ArtworkPlaceholderContent: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }
}

private struct CachedArtworkImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkPlaceholderContent()
            }
        }
        .task(id: url.absoluteString) {
            image = await ArtworkImageStore.shared.image(for: url)
        }
    }
}
