import AppKit
import SwiftUI
@testable import Spotiglass

/// Hosts SwiftUI views for ViewInspector tests on macOS.
@MainActor
enum ViewTestHost {
    private static var windows: [NSWindow] = []

    @discardableResult
    static func host<V: View>(_ view: V, size: CGSize = CGSize(width: 640, height: 480)) -> NSHostingController<V> {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
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
