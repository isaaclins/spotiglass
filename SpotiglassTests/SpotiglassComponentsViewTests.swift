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

    /// A background window drains the accent's saturation but keeps its brightness, so the
    /// default blue accent resolves to white. The selected pill used to inherit a light
    /// label there and became unreadable, which no unit test could see.
    func testContrastingLabelFlipsWithBackgroundLuminance() {
        XCTAssertEqual(SpotiglassDesign.contrastingLabel(on: .white), .black)
        XCTAssertEqual(SpotiglassDesign.contrastingLabel(on: .black), .white)

        let systemBlue = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)
        XCTAssertEqual(
            SpotiglassDesign.contrastingLabel(on: systemBlue), .white,
            "macOS paints white on the accent; a strict WCAG crossover would flip this to black")

        let drained = SpotiglassDesign.subduedForInactiveWindow(systemBlue)
        XCTAssertEqual(
            SpotiglassDesign.contrastingLabel(on: drained), .black,
            "Zero saturation keeps the accent's brightness, so the inactive fill needs a dark label")
    }

    /// 3:1 is the WCAG AA floor for user interface components, which is the right bar here:
    /// the point is that the label never disappears, not that it beats body-text contrast.
    func testContrastingLabelStaysLegibleOnAccentFills() throws {
        func luminance(_ color: NSColor) throws -> CGFloat {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }

        let fills: [NSColor] = [
            .white,
            .black,
            NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1),
            NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1),
        ]
        for fill in fills {
            let label = SpotiglassDesign.contrastingLabel(on: fill)
            let first = try luminance(label)
            let second = try luminance(fill)
            let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "label on \(fill) only reaches \(ratio):1")
        }
    }
}
