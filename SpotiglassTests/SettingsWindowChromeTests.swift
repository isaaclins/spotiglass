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
        let window = OffscreenTestWindow(
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

    /// The probe applies the titlebar in a `DispatchQueue.main.async` block. A run-loop pump
    /// can't run that block when the test itself runs inside one on the main queue (it did on
    /// CI, #466); suspending lets the main queue go on. The main queue runs its blocks in order,
    /// so once a block queued after the probe's has run, the probe's has too, however busy the
    /// machine is (#535).
    func testProbeViewConfiguresItsWindowOnceAttached() async throws {
        let window = makeWindow()
        window.contentView?.addSubview(UnifiedTitlebarProbeView())

        await withCheckedContinuation { queuedAfterTheProbe in
            DispatchQueue.main.async { queuedAfterTheProbe.resume() }
        }

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
