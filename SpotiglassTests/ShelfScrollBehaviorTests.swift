import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Spotiglass

/// Shift + mouse wheel on a horizontal shelf (#475).
///
/// With `.viewAligned`, SwiftUI snapped the shelf to a card edge after every
/// wheel notch. Logged on Home's Recently played: five Shift + wheel notches
/// proposed 10, 20, 30, 40 and 50 pt and every one was pulled back to 0, so the
/// row never moved; bigger notches jumped a whole card (168 pt) at a time.
@MainActor
final class ShelfScrollBehaviorTests: XCTestCase {
    /// Card width plus the gap between cards on Home and on artist pages.
    private let cardStride = HomeMediaCardView.artworkSize + SpotiglassDesign.spacingM

    /// What `.viewAligned` does to a target: the nearest card edge.
    private func snapToNearestCard(_ rect: inout CGRect) {
        rect.origin.x = (rect.origin.x / cardStride).rounded() * cardStride
    }

    private func settle(_ x: CGFloat, after input: ShelfScrollInput?) -> CGFloat {
        var rect = CGRect(x: x, y: 0, width: 900, height: 200)
        ShelfScrollTargetBehavior.settle(&rect, after: input, snapToCard: snapToNearestCard)
        return rect.origin.x
    }

    // MARK: - Which device scrolled

    func testShiftMouseWheelNotchIsAWheel() throws {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0
        ))
        cgEvent.flags = .maskShift
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(ShelfScrollInput(event: event), .wheel)
    }

    func testTrackpadSwipeAndItsMomentumAreAGesture() throws {
        for (phase, momentum) in [(1, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3)] as [(Int64, Int64)] {
            let cgEvent = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -30, wheel3: 0
            ))
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            XCTAssertEqual(ShelfScrollInput(event: event), .gesture, "phase \(phase), momentum \(momentum)")
        }
    }

    func testMonitorRemembersTheLatestScrollDevice() throws {
        let monitor = ShelfScrollInputMonitor()
        XCTAssertNil(monitor.lastInput)

        let wheel = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0
        ))
        monitor.record(try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertEqual(monitor.lastInput, .wheel)

        let swipe = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -30, wheel3: 0
        ))
        swipe.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        monitor.record(try XCTUnwrap(NSEvent(cgEvent: swipe)))
        XCTAssertEqual(monitor.lastInput, .gesture)
    }

    // MARK: - Where the shelf comes to rest

    func testShiftWheelNotchesMoveTheShelfByWhatTheWheelSends() {
        // The five targets SwiftUI proposed for five 10 pt notches on main.
        let proposed: [CGFloat] = [10, 20, 30, 40, 50]
        XCTAssertEqual(proposed.map { settle($0, after: .wheel) }, proposed)
    }

    func testFastWheelSpinDoesNotJumpAWholeCard() {
        // A 90 pt notch used to land on the next card edge, 168 pt away.
        XCTAssertEqual(settle(90, after: .wheel), 90)
        XCTAssertEqual(settle(cardStride + 30, after: .wheel), cardStride + 30)
    }

    func testTrackpadSwipeStillSettlesOnAWholeCard() {
        // Logged after a trackpad fling: proposed 678.8 pt, settled on the card at 672 pt.
        XCTAssertEqual(settle(678.8, after: .gesture), 4 * cardStride)
        XCTAssertEqual(settle(783, after: .gesture), 5 * cardStride)
    }

    func testScrollsWithoutAKnownDeviceKeepSettlingOnCards() {
        XCTAssertEqual(settle(90, after: nil), cardStride)
    }

    // MARK: - A real shelf

    func testShelfLaysOutAndScrollsWithTheBehavior() throws {
        let shelf = ScrollView(.horizontal) {
            HStack(spacing: SpotiglassDesign.spacingM) {
                ForEach(0..<12, id: \.self) { _ in
                    Rectangle().frame(width: HomeMediaCardView.artworkSize, height: 80)
                }
            }
            .scrollTargetLayout()
        }
        .frame(width: 600, height: 100)
        .shelfScrollBehavior()
        let controller = ViewTestHost.host(shelf, size: CGSize(width: 600, height: 120))
        defer { ViewTestHost.tearDownAll() }

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: controller.view))
        let documentWidth = try XCTUnwrap(scrollView.documentView).frame.width
        XCTAssertGreaterThan(documentWidth, scrollView.contentView.bounds.width, "the shelf has to overflow to scroll")
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    func testStartingTheMonitorTwiceIsHarmless() {
        let monitor = ShelfScrollInputMonitor()
        monitor.start()
        monitor.start()
        XCTAssertNil(monitor.lastInput)
    }

    // MARK: - Every shelf uses it

    func testNoViewSnapsEveryScrollToCardEdges() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Spotiglass", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var shelves: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "ShelfScrollBehavior.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".scrollTargetBehavior(.viewAligned") { offenders.append(url.lastPathComponent) }
            if text.contains(".shelfScrollBehavior()") { shelves.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "a mouse wheel can't scroll these shelves smoothly; use .shelfScrollBehavior()")
        XCTAssertEqual(Set(shelves), ["HomeView.swift", "ArtistDetailView.swift"])
    }
}
