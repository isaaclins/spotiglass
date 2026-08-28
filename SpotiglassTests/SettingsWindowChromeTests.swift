import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class SettingsWindowChromeTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testApplyUnifiedTitlebarInstallsToolbar() {
        let window = makeWindow()
        XCTAssertNil(window.toolbar)

        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)

        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.toolbar?.allowsUserCustomization, false)
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testApplyUnifiedTitlebarIsIdempotent() {
        let window = makeWindow()
        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)
        let first = window.toolbar

        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)

        XCTAssertTrue(first === window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testProbeViewConfiguresItsWindowOnceAttached() {
        let window = makeWindow()
        window.contentView?.addSubview(UnifiedTitlebarProbeView())

        AppKitTestSupport.pumpRunLoop()

        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testProbeViewIgnoresDetachedState() {
        let probe = UnifiedTitlebarProbeView()
        let window = makeWindow()
        window.contentView?.addSubview(probe)
        probe.removeFromSuperview()

        AppKitTestSupport.pumpRunLoop()

        XCTAssertNil(probe.window)
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testChromeHostsInSettingsWindowAndAppliesUnifiedTitlebar() throws {
        let controller = ViewTestHost.host(
            SettingsWindowChrome().frame(width: 0, height: 0),
            size: CGSize(width: 320, height: 240)
        )
        AppKitTestSupport.pumpRunLoop()

        let window = try XCTUnwrap(controller.view.window)
        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
    }
}
