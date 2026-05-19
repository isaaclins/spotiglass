import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class SpotiglassComponentsViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPillButtonRendersLabel() throws {
        let view = Button("Action") {}
            .buttonStyle(SpotiglassPillStyle(variant: .glass))
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Action"))
    }

    func testPillStyleVariantsAndPressed() throws {
        for variant: SpotiglassPillStyle.Variant in [.glass, .material(.regularMaterial), .accent] {
            let view = Button("Go") {}
                .buttonStyle(SpotiglassPillStyle(variant: variant, horizontalPadding: 12, verticalPadding: 8))
            ViewTestHost.host(view)
            XCTAssertNoThrow(try view.inspect().find(text: "Go"))
        }
        let pressed = Button("Press") {}
            .buttonStyle(SpotiglassPillStyle(variant: .accent))
            .simultaneousGesture(TapGesture().onEnded { })
        ViewTestHost.host(pressed)
        XCTAssertNoThrow(try pressed.inspect())
    }

    func testPillBackgroundAndSurfaceModifiers() throws {
        let pill = Text("Chip")
            .spotiglassPillBackground(variant: .glass)
        ViewTestHost.host(pill)
        XCTAssertNoThrow(try pill.inspect().find(text: "Chip"))

        let surface = Text("Tile")
            .spotiglassSurface(corner: .s, fill: .blue.opacity(0.2), stroke: .primary, strokeWidth: 1)
        ViewTestHost.host(surface)
        XCTAssertNoThrow(try surface.inspect().find(text: "Tile"))

        for corner: SpotiglassSurfaceModifier.CornerSize in [.s, .m, .l] {
            let sized = Text("C")
                .spotiglassSurface(corner: corner)
            ViewTestHost.host(sized)
            XCTAssertNoThrow(try sized.inspect())
        }
    }

    func testHoverPressableModifier() throws {
        let view = Text("Drag me")
            .hoverPressable(hoverScale: 1.05, pressScale: 0.92)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Drag me"))
    }
}
