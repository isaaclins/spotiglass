import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class ArtworkViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaceholderWhenURLMissing() throws {
        let view = ArtworkView(url: nil, size: 48)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
    }

    func testLoadsWhenURLPresent() throws {
        let view = ArtworkView(url: URL(string: "https://example.com/a.jpg"), size: 48)
        ViewTestHost.host(view, size: CGSize(width: 80, height: 80))
        XCTAssertNoThrow(try view.inspect().find(ViewType.Group.self))
    }

    func testCircularArtworkViewUsesCircularPlaceholder() throws {
        let view = CircularArtworkView(
            url: nil,
            size: SpotiglassDesign.detailHeaderArtworkSize
        )
        ViewTestHost.host(view, size: CGSize(width: 160, height: 160))
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
    }

    /// Loading, missing and failed all drew the same static glyph, so a cover
    /// that was still downloading looked exactly like one that would never
    /// arrive (#146).
    func testPlaceholderStatesAreDistinguishable() {
        let states: [ArtworkPlaceholderState] = [.none, .loading, .failed]
        let helpTexts = states.map { SpotiglassL10n.string($0.helpKey) }
        XCTAssertEqual(Set(helpTexts).count, states.count, "each state needs its own wording")
        XCTAssertFalse(helpTexts.contains { $0.isEmpty })

        // A failure is a different glyph, not the same one as a missing cover.
        XCTAssertNotEqual(ArtworkPlaceholderState.failed.systemImage, ArtworkPlaceholderState.none.systemImage)
        XCTAssertEqual(ArtworkPlaceholderState.none.systemImage, "music.note")
    }

    /// A spinner in a 28 point list thumbnail is noise, so progress only appears
    /// once the artwork is big enough to carry it.
    func testPlaceholderRendersAtThumbnailAndAtHeaderSize() throws {
        for state in [ArtworkPlaceholderState.none, .loading, .failed] {
            let thumbnail = ArtworkPlaceholderContent(state: state, size: 28)
            ViewTestHost.host(thumbnail, size: CGSize(width: 40, height: 40))
            XCTAssertNoThrow(try thumbnail.inspect())

            let header = ArtworkPlaceholderContent(state: state, size: 120)
            ViewTestHost.host(header, size: CGSize(width: 160, height: 160))
            XCTAssertNoThrow(try header.inspect())
        }
    }
}
