import SwiftUI
import ViewInspector
import XCTest

@testable import Spotiglass

@MainActor
final class SpotiglassDesignSystemTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testBrandPaletteTokensAreStable() {
        XCTAssertEqual(SpotiglassDesign.brandWarmAccentHex, "#D4A054")
        XCTAssertEqual(SpotiglassTypography.displayDesign, .serif)
        XCTAssertEqual(SpotiglassTypography.uiDesign, .rounded)
    }

    func testSelectionFillUsesWarmAccentForCurrentRow() {
        let dark = SpotiglassDesign.selectionFill(isCurrent: true, colorScheme: .dark)
        let light = SpotiglassDesign.selectionFill(isCurrent: true, colorScheme: .light)
        XCTAssertNotEqual(dark, .clear)
        XCTAssertNotEqual(light, .clear)
        XCTAssertEqual(SpotiglassDesign.selectionFill(isCurrent: false, colorScheme: .dark), .clear)
    }

    func testShellBackgroundHostsAtmosphericLayers() throws {
        let view = ShellBackground()
        ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        XCTAssertNoThrow(try view.inspect())
    }

    func testGlassPanelHostsContentWithWarmEdge() throws {
        let view = GlassPanel {
            Text("Panel content")
        }
        ViewTestHost.host(view, size: CGSize(width: 400, height: 200))
        XCTAssertNoThrow(try view.inspect().find(text: "Panel content"))
    }

    func testBrandMarkRendersAppName() throws {
        let view = SpotiglassBrandMark()
        ViewTestHost.host(view, size: CGSize(width: 360, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: AppMetadata.displayName))
    }

    func testEditorialEmptyStateRendersTitleAndMessage() throws {
        let view = EmptyStateView(title: "Nothing here", message: "Try another playlist")
        ViewTestHost.host(view, size: CGSize(width: 480, height: 320))
        XCTAssertNoThrow(try view.inspect().find(text: "Nothing here"))
        XCTAssertNoThrow(try view.inspect().find(text: "Try another playlist"))
    }
}
