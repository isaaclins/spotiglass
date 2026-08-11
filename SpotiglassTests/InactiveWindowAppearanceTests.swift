import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// macOS colors only the key window's controls. AppKit and the standard SwiftUI controls
/// do that themselves; everything this app draws by hand goes through
/// `SpotiglassDesign.accent(appearsActive:)` and `SpotiglassAccentStyle`, so these tests
/// pin down that decision rather than the rendering it feeds.
@MainActor
final class InactiveWindowAppearanceTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - The decision

    func testAccentKeepsTheSystemAccentWhileTheWindowIsKey() {
        XCTAssertEqual(SpotiglassDesign.accent(appearsActive: true), SpotiglassDesign.controlAccent)
    }

    func testAccentDiffersFromTheSystemAccentWhileTheWindowIsInactive() {
        XCTAssertNotEqual(SpotiglassDesign.accent(appearsActive: false), SpotiglassDesign.controlAccent)
        XCTAssertEqual(SpotiglassDesign.accent(appearsActive: false), SpotiglassDesign.inactiveAccent)
    }

    func testInactiveAccentCarriesNoColor() throws {
        let resolved = try XCTUnwrap(
            NSColor(SpotiglassDesign.accent(appearsActive: false)).usingColorSpace(.sRGB)
        )
        XCTAssertEqual(resolved.saturationComponent, 0, accuracy: 0.001)
    }

    func testInactiveAccentStaysOpaqueSoSubduedControlsKeepTheirWeight() throws {
        let resolved = try XCTUnwrap(
            NSColor(SpotiglassDesign.accent(appearsActive: false)).usingColorSpace(.sRGB)
        )
        XCTAssertEqual(resolved.alphaComponent, 1, accuracy: 0.001)
        XCTAssertGreaterThan(resolved.brightnessComponent, 0)
    }

    // MARK: - The desaturation itself

    func testSubduingDrainsSaturationAndKeepsHueBrightnessAndAlpha() throws {
        let vivid = NSColor(hue: 0.6, saturation: 0.9, brightness: 0.7, alpha: 0.8)
        let subdued = try XCTUnwrap(
            SpotiglassDesign.subduedForInactiveWindow(vivid).usingColorSpace(.sRGB)
        )

        XCTAssertEqual(subdued.saturationComponent, 0, accuracy: 0.001)
        XCTAssertEqual(subdued.brightnessComponent, 0.7, accuracy: 0.01)
        XCTAssertEqual(subdued.alphaComponent, 0.8, accuracy: 0.01)
    }

    func testSubduingWithAFullScaleLeavesAColorAlone() throws {
        let vivid = NSColor(hue: 0.1, saturation: 0.8, brightness: 0.6, alpha: 1)
        let untouched = try XCTUnwrap(
            SpotiglassDesign.subduedForInactiveWindow(vivid, saturationScale: 1).usingColorSpace(.sRGB)
        )

        XCTAssertEqual(untouched.saturationComponent, 0.8, accuracy: 0.01)
        XCTAssertEqual(untouched.hueComponent, 0.1, accuracy: 0.01)
    }

    func testSubduingWithAPartialScaleFadesRatherThanGreys() throws {
        let vivid = NSColor(hue: 0.35, saturation: 0.8, brightness: 0.6, alpha: 1)
        let faded = try XCTUnwrap(
            SpotiglassDesign.subduedForInactiveWindow(vivid, saturationScale: 0.25).usingColorSpace(.sRGB)
        )

        XCTAssertEqual(faded.saturationComponent, 0.2, accuracy: 0.01)
    }

    func testSubduingClampsAScaleThatWouldOversaturate() throws {
        let vivid = NSColor(hue: 0.35, saturation: 0.8, brightness: 0.6, alpha: 1)
        let clamped = try XCTUnwrap(
            SpotiglassDesign.subduedForInactiveWindow(vivid, saturationScale: 4).usingColorSpace(.sRGB)
        )

        XCTAssertEqual(clamped.saturationComponent, 1, accuracy: 0.001)
    }

    func testTheInactiveSaturationTokenGreysRatherThanFades() {
        XCTAssertEqual(SpotiglassDesign.inactiveWindowAccentSaturation, 0)
    }

    // MARK: - The shared shape style

    func testAccentStyleResolvesToTheSystemAccentInAKeyWindow() {
        var environment = EnvironmentValues()
        environment.appearsActive = true

        XCTAssertEqual(SpotiglassAccentStyle().resolve(in: environment), SpotiglassDesign.controlAccent)
    }

    func testAccentStyleResolvesToTheSubduedAccentInAnInactiveWindow() {
        var environment = EnvironmentValues()
        environment.appearsActive = false

        XCTAssertEqual(SpotiglassAccentStyle().resolve(in: environment), SpotiglassDesign.inactiveAccent)
        XCTAssertNotEqual(SpotiglassAccentStyle().resolve(in: environment), SpotiglassDesign.controlAccent)
    }

    func testAccentStyleFollowsTheWindowRatherThanAFixedColor() {
        var key = EnvironmentValues()
        key.appearsActive = true
        var inactive = EnvironmentValues()
        inactive.appearsActive = false

        XCTAssertNotEqual(
            SpotiglassAccentStyle().resolve(in: key),
            SpotiglassAccentStyle().resolve(in: inactive)
        )
    }

    func testShorthandAccentStyleIsTheSameDecision() {
        var environment = EnvironmentValues()
        environment.appearsActive = false
        let shorthand: SpotiglassAccentStyle = .spotiglassAccent

        XCTAssertEqual(shorthand.resolve(in: environment), SpotiglassAccentStyle().resolve(in: environment))
    }

    // MARK: - Custom drawn surfaces still render either way

    func testScrubberRendersInAnInactiveWindow() throws {
        let view = ScrubberView(
            displayFraction: 0.4,
            durationMilliseconds: 240_000,
            onSeek: { _ in },
            onDragUpdate: { _ in }
        )
        .environment(\.appearsActive, false)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 24))
        XCTAssertNoThrow(try view.inspect())
    }

    func testWaveformIconRendersInAnInactiveWindow() throws {
        let view = PlayingWaveformIcon(isPlaying: true).environment(\.appearsActive, false)

        ViewTestHost.host(view, size: CGSize(width: 24, height: 24))
        XCTAssertNoThrow(try view.inspect())
    }

    func testWaveformIconStillHonorsAnExplicitColorOverride() throws {
        let view = PlayingWaveformIcon(isPlaying: false, color: .red)

        ViewTestHost.host(view, size: CGSize(width: 24, height: 24))
        XCTAssertNoThrow(try view.inspect())
    }
}
