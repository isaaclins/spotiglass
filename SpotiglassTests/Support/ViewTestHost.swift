import AppKit
import SwiftUI
@testable import Spotiglass

/// Shared AppKit helpers for deterministic focus and layout in unit tests.
@MainActor
enum AppKitTestSupport {
    static func activateAppIfNeeded() {
        if NSApp == nil {
            _ = NSApplication.shared
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func pumpRunLoop(for duration: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @discardableResult
    static func makeFirstResponder(_ view: NSView, in window: NSWindow) -> Bool {
        activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        pumpRunLoop()
        return window.makeFirstResponder(view)
    }
}

/// Hosts SwiftUI views for ViewInspector tests on macOS.
@MainActor
enum ViewTestHost {
    private static var windows: [NSWindow] = []
    private static let hostLock = NSLock()

    @discardableResult
    static func host<V: View>(_ view: V, size: CGSize = CGSize(width: 640, height: 480)) -> NSHostingController<V> {
        hostLock.lock()
        defer { hostLock.unlock() }

        AppKitTestSupport.activateAppIfNeeded()
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop()
        return controller
    }

    static func tearDownAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    static func makeSettingsStore() throws -> SpotiglassSettingsStore {
        let dir = spotiglassTestsTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        return SpotiglassSettingsStore(fileURL: url)
    }
}
