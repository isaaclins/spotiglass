import AppKit
import SwiftUI
import XCTest
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

    static func pumpRunLoop(for duration: TimeInterval = 0.12) {
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

    /// Closes a test window without releasing it out from under ARC or leaving
    /// an AppKit responder pointing into the view tree being torn down.
    static func closeWindowSafely(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.makeFirstResponder(nil)
        window.close()
    }
}

/// Hosts SwiftUI views for ViewInspector tests on macOS.
@MainActor
enum ViewTestHost {
    private static var windows: [NSWindow] = []
    private static let hostLock = NSLock()

    static let appStorageSuiteName = "SpotiglassTests-AppStorage"

    /// Store that every hosted view's `@AppStorage` binds to.
    ///
    /// `@AppStorage` resolves against `UserDefaults.standard` unless the view
    /// tree supplies a store, and the test bundle shares the bundle identifier
    /// `com.isaaclins.spotiglass` with the shipping app. Without this, hosting a
    /// view that writes `queue.panel.visible` edits the real user's preferences.
    static let appStorageDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: appStorageSuiteName) else {
            fatalError("Could not create UserDefaults suite \(appStorageSuiteName)")
        }
        return defaults
    }()

    /// Hosts a view in a window that is deliberately never ordered on screen.
    ///
    /// An on-screen window makes macOS attach out-of-process view services to
    /// hosted controls (Safari's completion-list helper binds to text fields).
    /// When a later test tears its window down while such a service is still
    /// bound, the next `orderFront` raises an `NSRemoteView` assertion that
    /// kills the whole test process, so runs failed on whichever test happened
    /// to be next rather than on the code that changed (#364). Nothing here
    /// needs to be visible: layout, hit testing, ViewInspector and first
    /// responder all work in an off-screen window. Tests that genuinely need a
    /// key window ask for one through `AppKitTestSupport.makeFirstResponder`.
    @discardableResult
    static func host<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 640, height: 480)
    ) -> NSHostingController<AnyView> {
        hostLock.lock()
        defer { hostLock.unlock() }

        AppKitTestSupport.activateAppIfNeeded()
        let controller = NSHostingController(
            rootView: AnyView(view.defaultAppStorage(appStorageDefaults))
        )
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
        AppKitTestSupport.pumpRunLoop()
        return controller
    }

    static func tearDownAll() {
        for window in windows {
            AppKitTestSupport.closeWindowSafely(window)
        }
        windows.removeAll()
        appStorageDefaults.removePersistentDomain(forName: appStorageSuiteName)
    }

    /// Skips a test when running on a toolchain where ViewInspector traps while
    /// descending into a `GeometryReader`.
    ///
    /// ViewInspector 0.10.3 (the latest release, pinned at revision
    /// e9a06346499a3a889165647e3f23f8a7b2609a1c) constructs a `GeometryProxy`
    /// to traverse a `GeometryReader`. On the new SwiftUI shipped with macOS 26
    /// and later (this machine runs the macOS 27 beta), that construction trips
    /// an internal SwiftUI assertion and raises SIGTRAP, which kills the whole
    /// hosted XCTest process instead of failing a single test. The production
    /// `GeometryReader` (it measures library-row frames for drag-and-drop
    /// insertion targeting) is essential and must not change, so the only safe
    /// option is to skip the affected view-host tests until ViewInspector ships
    /// a build that supports this toolchain. Remove this guard, and its call
    /// sites, once that happens.
    ///
    /// The gate fires automatically on the incompatible toolchain (no opt-in env
    /// var). macOS 26 is the first version on the new SwiftUI, so anything at or
    /// above it is gated, which covers the current machine.
    static func skipIfViewInspectorGeometryUnsupported(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else { return }
        throw XCTSkip(
            "Skipped on macOS \(version.majorVersion): ViewInspector 0.10.3 traps (SIGTRAP) "
                + "constructing a GeometryProxy to traverse the sidebar GeometryReader on the new SwiftUI. "
                + "Remove this guard once ViewInspector supports the toolchain.",
            file: file,
            line: line
        )
    }

    private static var spotiglassBundle: Bundle {
        if let bundle = Bundle.allBundles.first(where: { $0.bundleURL.pathExtension == "app" }) {
            return bundle
        }
        return Bundle(for: SpotiglassSettingsStore.self)
    }

    static func localizedString(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: spotiglassBundle)
    }

    /// Finds copy from ``Localizable.xcstrings`` (unit tests host in the test bundle, not `.main`).
    static func assertFindLocalizedText<V: View>(
        _ key: String,
        in view: V,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved = localizedString(key)
        var lastError: Error?
        for candidate in [resolved, key] {
            for _ in 0 ..< 10 {
                AppKitTestSupport.pumpRunLoop(for: 0.05)
                do {
                    _ = try view.inspect().find(text: candidate)
                    return
                } catch {
                    lastError = error
                }
            }
        }
        XCTFail(
            "Expected localized text for \"\(key)\" in view hierarchy: \(String(describing: lastError))",
            file: file,
            line: line
        )
    }

    /// ViewInspector can miss text until SwiftUI finishes laying out the hosted window.
    static func assertFindText<V: View>(
        _ text: String,
        in view: V,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastError: Error?
        for _ in 0 ..< 10 {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
            do {
                _ = try view.inspect().find(text: text)
                return
            } catch {
                lastError = error
            }
        }
        XCTFail(
            "Expected text \"\(text)\" in view hierarchy: \(String(describing: lastError))",
            file: file,
            line: line
        )
    }

    static func makeSettingsStore() throws -> SpotiglassSettingsStore {
        let dir = spotiglassTestsTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        return SpotiglassSettingsStore(fileURL: url)
    }
}
