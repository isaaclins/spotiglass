import AppKit
import SwiftUI

struct CommandPaletteArtistAvatar: View {
    let imageURL: URL?
    let fallbackSystemName: String
    private let diameter: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
        }
        .task(id: imageURL?.absoluteString ?? "") {
            guard let imageURL else {
                loadedImage = nil
                return
            }
            loadedImage = await ArtworkImageStore.shared.image(for: imageURL)
        }
    }
}

/// Square album-cover thumbnail for `.tracks` and `.thisPlaylist` palette rows.
/// Resolves through `ArtworkImageStore`, which serves from memory/disk before
/// falling back to a single network fetch on a cold cache.
struct CommandPaletteTrackArtwork: View {
    let imageURL: URL
    let fallbackSystemName: String
    private let side: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
        }
        .task(id: imageURL.absoluteString) {
            loadedImage = await ArtworkImageStore.shared.image(for: imageURL)
        }
    }
}
