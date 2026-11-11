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
/// draws library covers only inside a window, so the preview has to take the cover that already
/// shows on screen. MusicKit draws nothing for a made-up artwork, so a magenta tile carrying the
/// same marker as ``MusicKitArtwork`` stands in for the drawn cover.
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

    /// Shows a stand-in cover on screen the way a sidebar or pin row shows a library cover.
    /// `inSidebar` puts it inside a view that draws nothing when cached, like the sidebar;
    /// `backdrop` is what the row draws behind it.
    private func showCoverOnScreen(
        url: String, itemKey: String?, fill: Color = Color(red: 1, green: 0, blue: 1), inSidebar: Bool = false,
        backdrop: Color = .clear
    ) throws {
        let marked = fill
            .frame(width: 40, height: 40)
            .background(OnScreenArtworkMarker(url: try XCTUnwrap(URL(string: url)), itemKey: itemKey))
        show(marked, backdrop: backdrop, inSidebar: inSidebar)
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

    /// Share of the drawn pill that is the cover's magenta.
    private func coverPixelCount(in item: PinnedItem) throws -> Int {
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
        return stride(from: 0, to: pixels.count, by: 4).filter { i in
            pixels[i] > 220 && pixels[i + 1] < 60 && pixels[i + 2] > 220
        }.count
    }

    func testLibraryPinDragPreviewShowsTheCoverOnScreen() throws {
        let url = "musicKit://artwork/transient/40x40?id=ROAD449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil)

        let size = SpotiglassDesign.Layout.thumbnailSize
        // Most of the preview's cover square is the cover, not the note on grey.
        XCTAssertGreaterThan(try coverPixelCount(in: pin), Int(size * size * 0.6))
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
    /// nothing when cached (its glass has its own layers), and only the row and cell views draw
    /// the cover. Taking the cover from the root gave an empty tile in the preview.
    func testLibraryCoverInTheSidebarShowsInThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=SIDEBAR449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil, inSidebar: true)

        let size = SpotiglassDesign.Layout.thumbnailSize
        XCTAssertGreaterThan(try coverPixelCount(in: pin), Int(size * size * 0.6))
    }

    /// A row whose cover MusicKit hasn't drawn yet shows the see-through placeholder; the
    /// preview keeps its note instead of copying an empty tile.
    func testCoverNotDrawnYetKeepsThePlaceholder() throws {
        let url = "musicKit://artwork/transient/40x40?id=NOTDRAWN449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil, fill: Color.gray.opacity(0.16))

        XCTAssertNil(DragPreviewArtwork.initialImage(
            artworkURL: pin.artworkURL, requestURL: pin.artworkURL, artworkKey: pin.id
        ))
    }

    /// The main column and Home draw a solid background behind their rows. A cover MusicKit
    /// hasn't drawn (a cloud-only song, or one still loading) shows the see-through placeholder
    /// over it, which is opaque there; the preview copied that flat tile instead of its note.
    func testCoverNotDrawnYetOverASolidBackgroundKeepsThePlaceholder() throws {
        for (name, backdrop) in [("light", Color.white), ("dark", Color(white: 0.12))] {
            let url = "musicKit://artwork/transient/40x40?id=SOLID449\(name)"
            try showCoverOnScreen(url: url, itemKey: nil, fill: Color.gray.opacity(0.16), backdrop: backdrop)
            XCTAssertNil(
                DragPreviewArtwork.initialImage(artworkURL: URL(string: url), requestURL: nil, artworkKey: nil),
                "\(name) background"
            )
        }
    }

    /// A drawn cover over that solid background is still taken.
    func testCoverOverASolidBackgroundShowsInThePreview() throws {
        let url = "musicKit://artwork/transient/40x40?id=ONWHITE449"
        let pin = libraryPlaylistPin(artwork: url)
        try showCoverOnScreen(url: url, itemKey: nil, backdrop: .white)

        let size = SpotiglassDesign.Layout.thumbnailSize
        XCTAssertGreaterThan(try coverPixelCount(in: pin), Int(size * size * 0.6))
    }

    /// The covers the app draws carry the marker: without it nothing is ever found on screen.
    /// MusicKit draws nothing for a made-up artwork, so a cover-like gradient behind it shows
    /// through where the cover would be.
    func testMusicKitArtworkMarksItsCoverForThePreview() throws {
        let artwork = try AppleMusicFixtures.decode(
            Artwork.self,
            #"{"url":"musicKit://artwork/transient/{w}x{h}?id=MARKED449","width":600,"height":600}"#
        )
        let url = try XCTUnwrap(AppleMusicItemMapping.artworkURL(artwork, size: 40))
        show(
            ZStack {
                LinearGradient(colors: [.red, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                MusicKitArtwork(url: url, width: 40, height: 40)
            }
            .frame(width: 40, height: 40)
        )

        XCTAssertNotNil(DragPreviewArtwork.initialImage(artworkURL: url, requestURL: nil, artworkKey: nil))
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
