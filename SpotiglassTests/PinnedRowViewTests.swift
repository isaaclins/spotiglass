import AppKit
import MusicKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PinnedRowViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaylistPinRendersTitle() throws {
        let pin = PinnedItem.playlist(
            MusicPlaylistSummary(
                id: "p1", name: "Daily",
                ownerID: "test-owner", ownerName: "Me",
                imageURL: nil, trackCount: 3, snapshotID: "s"
            )
        )
        let view = PinnedRowView(item: pin, isSelected: false, onUnpin: {})
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Daily"))
    }

    func testStaleBadge() throws {
        var pin = PinnedItem.playlist(
            MusicPlaylistSummary(
                id: "p2", name: "Gone",
                ownerID: "test-owner", ownerName: "Me",
                imageURL: nil, trackCount: 0, snapshotID: "s"
            )
        )
        pin.isStale = true
        let view = PinnedRowView(item: pin, onUnpin: {})
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Unavailable"))
    }

    func testLikedSongsAndArtistRows() throws {
        let liked = PinnedRowView(
            item: .likedSongs(ownerDisplay: "You", artworkURL: nil),
            isSelected: true,
            onUnpin: {}
        )
        ViewTestHost.host(liked)
        XCTAssertNoThrow(try liked.inspect().find(text: "Liked Songs"))

        // Unselected liked songs takes the other branch of the heart glyph.
        let likedUnselected = PinnedRowView(
            item: .likedSongs(ownerDisplay: "You", artworkURL: nil),
            isSelected: false,
            onUnpin: {}
        )
        ViewTestHost.host(likedUnselected)
        XCTAssertNoThrow(try likedUnselected.inspect().find(text: "Liked Songs"))

        let artist = PinnedRowView(
            item: .artist(MusicArtist(id: "a1", name: "M83", imageURL: nil, uri: "spotify:artist:a1")),
            onUnpin: {}
        )
        ViewTestHost.host(artist)
        XCTAssertNoThrow(try artist.inspect().find(text: "M83"))

        // With an image URL the row renders CachedCircularArtwork instead of the
        // person glyph, which is the branch the other cases never reach.
        let artistWithArtwork = PinnedRowView(
            item: .artist(MusicArtist(
                id: "a2",
                name: "Air",
                imageURL: URL(string: "https://example.com/artist.jpg"),
                uri: "spotify:artist:a2"
            )),
            onUnpin: {}
        )
        ViewTestHost.host(artistWithArtwork)
        XCTAssertNoThrow(try artistWithArtwork.inspect().find(text: "Air"))
    }

    func testAlbumAndTrackPins() throws {
        let album = PinnedRowView(
            item: .album(MusicAlbum(
                id: "al1", name: "Hurry Up", artists: ["M83"], imageURL: nil, uri: "spotify:album:al1"
            )),
            onUnpin: {}
        )
        ViewTestHost.host(album)
        XCTAssertNoThrow(try album.inspect().find(text: "Hurry Up"))

        let track = PinnedRowView(
            item: .track(MusicTrack(
                id: "t1",
                name: "Midnight",
                artists: ["M83"],
                albumArtworkURL: URL(string: "https://example.com/a.jpg"),
                durationMilliseconds: 240_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:t1"
            )),
            onUnpin: {}
        )
        ViewTestHost.host(track)
        XCTAssertNoThrow(try track.inspect().find(text: "Midnight"))
    }

    func testDragPillKinds() throws {
        let playlist = PinnedItem.playlist(
            MusicPlaylistSummary(
                id: "p3", name: "Mix",
                ownerID: "test-owner", ownerName: "Me",
                imageURL: nil, trackCount: 1, snapshotID: "s"
            )
        )
        ViewTestHost.host(PinnedItemDragPill(item: playlist))
        ViewTestHost.host(PinnedItemDragPill(item: .likedSongs(ownerDisplay: "You", artworkURL: nil)))
    }
}

/// Dragging an Apple Music library pin showed the plain note instead of its cover (#449).
/// macOS takes the drag image at once, the way `ImageRenderer` draws the pill here, and MusicKit
/// draws library covers only inside a window, so the preview takes the image MusicKit put in the
/// cover on screen. MusicKit draws nothing for a made-up artwork, so an `Image` carrying the same
/// marker as ``MusicKitArtwork`` stands in for the drawn cover: both are an image layer.
@MainActor
final class PinnedItemDragPillLibraryCoverTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach(AppKitTestSupport.closeWindowSafely)
        windows = []
        super.tearDown()
    }

    private func libraryPlaylistPin(artwork: String) -> PinnedItem {
        PinnedItem.playlist(
            MusicPlaylistSummary(
                id: "p.library449", name: "Road Trip",
                ownerID: "me", ownerName: "Me",
                imageURL: URL(string: artwork), trackCount: 12, snapshotID: "applemusic"
            )
        )
    }

    /// A 40 x 40 cover image: `fill` everywhere, `centre` in its middle third, `top` over its
    /// upper half.
    private static func tile(_ fill: NSColor, centre: NSColor? = nil, top: NSColor? = nil) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill(using: .copy)
        if let centre {
            centre.setFill()
            NSRect(x: 13, y: 13, width: 14, height: 14).fill()
        }
        if let top {
            top.setFill()
            NSRect(x: 0, y: 20, width: 40, height: 20).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.addRepresentation(rep)
        return image
    }

    private static let magenta = tile(NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
    /// What MusicKit's cover holds before the artwork has loaded.
    private static let notDrawnYet = tile(.clear)

    /// Shows a stand-in cover on screen the way a row shows a library cover: the see-through
    /// placeholder, the cover image with the marker behind it, over the row's `backdrop`.
    /// `badge` draws a green square over the cover, like a pin badge; `dim` lays a same-sized
    /// half-black image over it; `imagePlaceholder` draws the placeholder as an image;
    /// `emptyCoverLayer` stands in for MusicKit's cover layer before it has any contents;
    /// `border` strokes an outline over it, like the row's; a `cover` that isn't square is fitted
    /// inside its frame, not stretched; `round` clips it like an artist's cover; `inSidebar` puts it
    /// inside a view that draws nothing when cached.
    private func showCoverOnScreen(
        url: String, itemKey: String?, cover: NSImage = magenta, backdrop: Color = .clear,
        badge: Bool = false, dim: Bool = false, imagePlaceholder: Bool = false, round: Bool = false,
        emptyCoverLayer: Bool = false, side: CGFloat = 40, border: Bool = false, inSidebar: Bool = false
    ) throws {
        let marker = OnScreenArtworkMarker(url: try XCTUnwrap(URL(string: url)), itemKey: itemKey)
        let row = ZStack {
            if imagePlaceholder {
                Image(nsImage: Self.tile(NSColor(white: 0.5, alpha: 0.3))).resizable()
            } else {
                Color.gray.opacity(0.16)
            }
            if emptyCoverLayer {
                EmptyLayer().frame(width: side, height: side).background(marker)
            } else {
                Image(nsImage: cover).resizable().scaledToFit().frame(width: side, height: side).background(marker)
            }
            if dim { Image(nsImage: Self.tile(NSColor(white: 0, alpha: 0.5))).resizable().frame(width: side, height: side) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: round ? 20 : 4))
        .overlay {
            // 3 pt rather than the rows' 1 pt, so the outline reaches the points the preview
            // samples at any scale.
            if border { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black, lineWidth: 3) }
        }
        .overlay(alignment: .topTrailing) {
            if badge { Color(red: 0, green: 1, blue: 0).frame(width: 14, height: 14) }
        }
        show(row, backdrop: backdrop, inSidebar: inSidebar)
    }

    /// Puts `cover` in the middle of an 80 pt window over `backdrop`.
    private func show(_ cover: some View, backdrop: Color = .clear, inSidebar: Bool = false) {
        let cover = cover.frame(width: 80, height: 80).background(backdrop)
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        if inSidebar {
            let sidebar = DrawsNothingWhenCachedView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
            let host = NSHostingView(rootView: cover)
            host.frame = sidebar.bounds
            sidebar.addSubview(host)
            window.contentView = sidebar
        } else {
            window.contentView = NSHostingView(rootView: cover)
        }
        window.orderFrontRegardless()
        windows.append(window)
        AppKitTestSupport.pumpRunLoop()
    }

    /// Pixels of the drawn pill that match `matches`, in its upper or lower half when `half` is
    /// given.
    private func pixelCount(
        in item: PinnedItem, half: VerticalEdge? = nil, _ matches: (UInt8, UInt8, UInt8) -> Bool
    ) throws -> Int {
        let renderer = ImageRenderer(content: PinnedItemDragPill(item: item))
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row 0 of the buffer is the top of the image.
        let rows: Range<Int> = switch half {
        case .top: 0..<height / 2
        case .bottom: (height + 1) / 2..<height
        case nil: 0..<height
        }
        return rows.flatMap { row in (0..<width).map { (row * width + $0) * 4 } }
            .filter { matches(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.count
    }

    private func coverPixelCount(in item: PinnedItem) throws -> Int {
        try pixelCount(in: item) { r, g, b in r > 220 && g < 60 && b > 220 }
    }

    private var mostOfTheCoverSquare: Int {
        let size = SpotiglassDesign.Layout.thumbnailSize
        return Int(size * size * 0.6)
    }

    func testLibraryPinDragPreviewShowsTheCoverOnScreen() throws {
        let url = "musicKit://artwork/transient/40x40?id=ROAD449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil)

        // Most of the preview's cover square is the cover, not the note on grey.
        XCTAssertGreaterThan(try coverPixelCount(in: pin), mostOfTheCoverSquare)
    }

    /// Pins keep last session's library URL, which no view draws under anymore; the row draws the
    /// cover under the pin's ID, so the preview finds it there.
    func testPinSavedWithLastSessionsURLFindsItsCoverByPinID() throws {
        let pin = libraryPlaylistPin(artwork: "musicKit://artwork/transient/40x40?id=OLD449")
        try showCoverOnScreen(url: "musicKit://artwork/transient/40x40?id=NEW449", itemKey: pin.id)

        XCTAssertNotNil(DragPreviewArtwork.initialImage(
            artworkURL: pin.artworkURL, requestURL: pin.artworkURL, artworkKey: pin.id
        ))
        XCTAssertGreaterThan(try coverPixelCount(in: pin), 0)
    }

    /// In the app's sidebar, the views from its scroll view out to the window's root draw
    /// nothing when cached (its glass has its own layers). A picture of the window gave an
    /// empty tile in the preview.
    func testLibraryCoverInTheSidebarShowsInThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=SIDEBAR449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil, inSidebar: true)

        XCTAssertGreaterThan(try coverPixelCount(in: pin), mostOfTheCoverSquare)
    }

    /// Until the artwork loads (or never, for a cloud-only song) MusicKit's cover is empty and
    /// the see-through placeholder shows. Over the main column's and Home's solid background
    /// that placeholder is an opaque tile; the preview keeps its own note either way.
    func testCoverNotDrawnYetKeepsThePlaceholder() throws {
        for (name, backdrop) in [("clear", Color.clear), ("light", .white), ("dark", Color(white: 0.12))] {
            let url = "musicKit://artwork/transient/40x40?id=NOTDRAWN449\(name)"
            try showCoverOnScreen(url: url, itemKey: nil, cover: Self.notDrawnYet, backdrop: backdrop)
            XCTAssertNil(
                DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil),
                "\(name) background"
            )
        }
    }

    /// A same-sized image laid over a cover that isn't drawn yet is not the cover.
    func testImageOverAnUndrawnCoverIsNotTakenForIt() throws {
        let url = "musicKit://artwork/transient/40x40?id=DIMMED449"
        try showCoverOnScreen(url: url, itemKey: nil, cover: Self.notDrawnYet, dim: true)
        XCTAssertNil(DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil))
    }

    /// MusicKit's cover layer before it has any contents still counts as the cover: a same-sized
    /// layer over it (the now-playing cover has a lyrics button over it) isn't taken instead.
    func testImageOverAnEmptyCoverLayerIsNotTakenForIt() throws {
        let url = "musicKit://artwork/transient/40x40?id=EMPTY449"
        try showCoverOnScreen(url: url, itemKey: nil, dim: true, emptyCoverLayer: true)
        XCTAssertNil(DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil))
    }

    /// A cover that doesn't fill its frame (a non-square one, fitted) has no layer with the
    /// frame; the row's outline over it does, but an outline is not a cover.
    func testOutlineOverACoverThatDoesNotFillItsFrameIsNotTaken() throws {
        let url = "musicKit://artwork/transient/40x40?id=WIDE449"
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 22, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 40, height: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
        let wide = NSImage(size: NSSize(width: 40, height: 22))
        wide.addRepresentation(rep)

        try showCoverOnScreen(url: url, itemKey: nil, cover: wide, border: true)
        XCTAssertNil(DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil))
    }

    /// A row that switches to another cover answers for the new one, and no longer for the old.
    func testRowThatSwitchesCoverAnswersForTheNewOne() throws {
        let old = try XCTUnwrap(URL(string: "musicKit://artwork/transient/40x40?id=SWITCH449a"))
        let new = try XCTUnwrap(URL(string: "musicKit://artwork/transient/40x40?id=SWITCH449b"))
        let shown = ShownCover(url: old)
        show(SwitchingCover(shown: shown, image: Self.magenta))
        XCTAssertNotNil(DragPreviewArtwork.initialImage(artworkURL: old, requestURL: nil, artworkKey: nil))

        shown.url = new
        AppKitTestSupport.pumpRunLoop()
        XCTAssertNotNil(DragPreviewArtwork.initialImage(artworkURL: new, requestURL: nil, artworkKey: nil))
        XCTAssertNil(DragPreviewArtwork.initialImage(artworkURL: old, requestURL: nil, artworkKey: nil))
    }

    /// With the same cover on screen twice, the preview takes the larger copy.
    func testPreviewTakesTheLargestCopyOnScreen() throws {
        let url = "musicKit://artwork/transient/40x40?id=TWICE449"
        try showCoverOnScreen(url: url, itemKey: nil, side: 20)
        try showCoverOnScreen(url: url, itemKey: nil, side: 60)
        let image = try XCTUnwrap(DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil))
        XCTAssertEqual(image.size.width, 60)
    }

    /// The placeholder behind the cover is never taken for it, even when it is an image too.
    func testImagePlaceholderBehindAnUndrawnCoverIsNotTakenForIt() throws {
        let url = "musicKit://artwork/transient/40x40?id=BEHIND449"
        try showCoverOnScreen(url: url, itemKey: nil, cover: Self.notDrawnYet, imagePlaceholder: true)
        XCTAssertNil(DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil))
    }

    /// A white cover with a small motif on the light window background is still a cover.
    func testLightCoverOnALightBackgroundShowsInThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=WHITE449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(
            url: url, itemKey: nil,
            cover: Self.tile(.white, centre: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
            backdrop: Color(white: 0.93)
        )

        XCTAssertGreaterThan(try coverPixelCount(in: pin), 0, "the cover's motif")
        XCTAssertGreaterThan(try pixelCount(in: pin) { r, g, b in r > 245 && g > 245 && b > 245 }, mostOfTheCoverSquare / 2)
    }

    /// The cover keeps its orientation in the preview.
    func testCoverIsTheRightWayUpInThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=UPRIGHT449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(
            url: url, itemKey: nil, cover: Self.tile(.white, top: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        )

        let magenta: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 220 && g < 60 && b > 220 }
        XCTAssertGreaterThan(try pixelCount(in: pin, half: .top, magenta), 0)
        XCTAssertEqual(try pixelCount(in: pin, half: .bottom, magenta), 0, "the cover's top half is magenta")
    }

    /// The preview shows the cover, not what the row draws over it (a pin badge).
    func testBadgeOverTheCoverStaysOutOfThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=BADGE449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil, badge: true)

        XCTAssertGreaterThan(try coverPixelCount(in: pin), mostOfTheCoverSquare)
        XCTAssertEqual(try pixelCount(in: pin) { r, g, b in r < 60 && g > 220 && b < 60 }, 0, "the badge's green")
    }

    /// Library artists get the same: their round cover shows in the artist pill.
    func testLibraryArtistDragPreviewShowsTheCoverOnScreen() throws {
        let url = "musicKit://artwork/transient/40x40?id=ARTIST449"
        let pin = PinnedItem.artist(MusicArtist(id: "r.artist449", name: "M83", imageURL: URL(string: url), uri: "applemusic:artist:r.artist449"))
        try showCoverOnScreen(url: url, itemKey: nil, round: true)

        XCTAssertGreaterThan(try coverPixelCount(in: pin), mostOfTheCoverSquare / 2)
    }

    /// A library artist whose cover isn't drawn on screen keeps the artist placeholder. The
    /// pill's fallback drew MusicKit's view, which can't be drawn outside a window, and the
    /// preview showed SwiftUI's yellow "can't draw this" box.
    func testLibraryArtistNotOnScreenKeepsThePlaceholder() throws {
        let artwork = try AppleMusicFixtures.decode(
            Artwork.self,
            #"{"url":"musicKit://artwork/transient/{w}x{h}?id=OFFSCREENARTIST449","width":600,"height":600}"#
        )
        let url = try XCTUnwrap(AppleMusicItemMapping.artworkURL(artwork, size: 40))
        let pin = PinnedItem.artist(MusicArtist(
            id: "r.offscreen449", name: "M83", imageURL: url, uri: "applemusic:artist:r.offscreen449"
        ))

        let yellow = try pixelCount(in: pin) { r, g, b in r > 200 && g > 200 && b < 80 }
        XCTAssertEqual(yellow, 0, "SwiftUI's can't-draw box")
    }

    /// The covers the app draws carry the marker: without it nothing is ever found on screen.
    func testMusicKitArtworkCarriesTheMarker() throws {
        let artwork = try AppleMusicFixtures.decode(
            Artwork.self,
            #"{"url":"musicKit://artwork/transient/{w}x{h}?id=MARKED449","width":600,"height":600}"#
        )
        let url = try XCTUnwrap(AppleMusicItemMapping.artworkURL(artwork, size: 40))
        let view = MusicKitArtwork(url: url, width: 40, height: 40)
        XCTAssertNoThrow(try view.inspect().find(OnScreenArtworkMarker.self))
    }

    func testLibraryCoverNotOnScreenKeepsThePlaceholder() throws {
        let pin = libraryPlaylistPin(artwork: "musicKit://artwork/transient/40x40?id=NOWHERE449")
        XCTAssertNil(DragPreviewArtwork.initialImage(
            artworkURL: pin.artworkURL, requestURL: pin.artworkURL, artworkKey: pin.id
        ))
    }

    /// Catalog and Spotify covers still come from the image cache, never from the screen.
    func testDownloadedCoverIsNotTakenFromTheScreen() throws {
        let url = "https://example.com/catalog449.jpg"
        try showCoverOnScreen(url: url, itemKey: nil)
        XCTAssertNil(DragPreviewArtwork.initialImage(
            artworkURL: URL(string: url), requestURL: URL(string: url), artworkKey: nil
        ))
    }
}

/// Stands in for the sidebar's glass and scroll views, which draw nothing into a cached image.
private final class DrawsNothingWhenCachedView: NSView {
    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {}
}

/// A layer with no contents and nothing inside: MusicKit's cover before it is filled.
private struct EmptyLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class ShownCover: ObservableObject {
    @Published var url: URL
    init(url: URL) { self.url = url }
}

/// One row whose cover changes, the way a reused list row shows another item.
private struct SwitchingCover: View {
    @ObservedObject var shown: ShownCover
    let image: NSImage

    var body: some View {
        Image(nsImage: image).resizable().frame(width: 40, height: 40)
            .background(OnScreenArtworkMarker(url: shown.url, itemKey: nil))
    }
}
