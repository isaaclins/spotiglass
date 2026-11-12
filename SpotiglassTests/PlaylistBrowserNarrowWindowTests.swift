import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Resizes a real browser window across the sidebar's collapse width and checks the columns the
/// split view lays out: the sidebar is either collapsed or fully inside the window, and so is the
/// detail column. At 640 pt the sidebar kept its 320 pt next to the detail column's 360 pt, so the
/// window cut off both (#459).
@MainActor
final class PlaylistBrowserNarrowWindowTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private static let widths: [CGFloat] = [900, 700, 680, 660, 640, 620, 640, 660, 700, 900]

    func testNoColumnIsCutOffAcrossTheCollapseWidthWithSpotify() async throws {
        try await assertNoColumnIsCutOff(service: .spotify)
    }

    func testNoColumnIsCutOffAcrossTheCollapseWidthWithAppleMusic() async throws {
        try await assertNoColumnIsCutOff(service: .appleMusic)
    }

    /// The browser in a window the test resizes, set up as each service shows it.
    private func hostBrowser(
        service: MusicService,
        likeTheAppsWindow: Bool = false
    ) async throws -> (NSHostingController<AnyView>, NSWindow, BrowserWidthSampler) {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Night Drive"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Deep Focus"),
            ])],
            trackResults: [:]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let settings = try ViewTestHost.makeSettingsStore()
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.spotify, .appleMusic], active: service
        ))
        let palette = CommandPaletteManager()
        let tokens = NarrowWindowTokenProvider()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        // The same browser both services show; Apple Music's is set up as AppleMusicBrowserRoot
        // sets it up (no Disconnect, its own player bar state).
        let header = AnyView(MusicServiceSwitcher(
            store: services, keymapStore: palette.keymapStore, switchTo: { _ in }, add: { _ in }
        ))
        let sampler = BrowserWidthSampler()
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: palette,
            signOut: {},
            playbackMode: service == .appleMusic
                ? .unavailable(SpotiglassL10n.string("error.playback.appleMusic.subscription.message"))
                : .live,
            canDisconnect: service != .appleMusic,
            sidebarHeader: header,
            widthSampler: sampler
        )
        .environmentObject(store)
        .environmentObject(settings)
        .environmentObject(LyricsOverlayController())

        // By default the window takes each width the test gives it, and the sidebar collapses
        // and comes back without animation, so each width is read at its final layout (#532).
        let controller = ViewTestHost.host(
            view, size: CGSize(width: 900, height: 600), measuresLayout: !likeTheAppsWindow
        )
        let window = try XCTUnwrap(controller.view.window)
        if likeTheAppsWindow {
            // As the app's window: resizable, and its minimum size follows the content's
            // (`.windowResizability(.contentMinSize)`), so AppKit can grow it for a column.
            window.styleMask.insert(.resizable)
            controller.sizingOptions = [.minSize]
        }
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        return (controller, window, sampler)
    }

    private func assertNoColumnIsCutOff(service: MusicService) async throws {
        let (controller, window, sampler) = try await hostBrowser(service: service)

        var collapsedAt: [CGFloat] = []
        for width in Self.widths {
            window.setContentSize(CGSize(width: width, height: 600))
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop(for: 0.6)
            Self.waitForCommittedWidth(width, sampler)

            let split = try XCTUnwrap(Self.splitView(in: controller.view), "no split view at \(width) pt")
            let columns = split.arrangedSubviews
            XCTAssertEqual(columns.count, 2, "at \(width) pt")
            guard let sidebar = columns.first, let detail = columns.last else { continue }
            let bounds = controller.view.bounds
            // The detail column runs under the floating sidebar, so its own frame starts at the
            // window's edge; the page itself gets what lies right of the sidebar.
            let detailFrame = detail.convert(detail.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(detailFrame.minX, bounds.minX - 0.5, "split view cut off at \(width) pt")
            XCTAssertLessThanOrEqual(detailFrame.maxX, bounds.maxX + 0.5, "detail column cut off at \(width) pt")
            if Self.isCollapsed(sidebar, in: split) {
                collapsedAt.append(width)
                XCTAssertGreaterThanOrEqual(
                    detailFrame.width, SpotiglassDesign.detailColumnMinWidth - 0.5, "detail column at \(width) pt"
                )
                continue
            }
            let sidebarFrame = sidebar.convert(sidebar.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(sidebarFrame.minX, bounds.minX - 0.5, "sidebar cut off at \(width) pt")
            XCTAssertGreaterThanOrEqual(
                detailFrame.maxX - sidebarFrame.maxX, SpotiglassDesign.detailColumnMinWidth - 0.5,
                "detail column squeezed next to the sidebar at \(width) pt (sidebar \(sidebarFrame), detail \(detailFrame))"
            )
        }
        // It collapses only where it doesn't fit, and comes back once it does. At 680 the two
        // columns fit exactly on macOS 27, but macOS 26's split view needs 8 pt more and ran past
        // both edges there, so 680 collapses too.
        XCTAssertEqual(collapsedAt, [680, 660, 640, 620, 640, 660], "collapsed at \(collapsedAt)")

        // Dragging the sidebar wider stops where the detail column still has its minimum: a
        // drag to 620 in an 800 pt window used to push both columns past the window's edges.
        // The resize ends the way a fast live resize does: the last frame comes one frame after
        // the one before it, inside the width throttle, and crosses nothing. The drag limit used
        // to stay at the 850 pt that frame before it committed.
        for (width, wait) in [(CGFloat(850), 0.016), (800, 0.1)] {
            window.setContentSize(CGSize(width: width, height: 600))
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop(for: wait)
        }
        // The 800 pt frame came inside the throttle: it lands by the trailing commit's timer.
        Self.waitForCommittedWidth(800, sampler)
        let split = try XCTUnwrap(Self.splitView(in: controller.view))
        split.setPosition(620, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.6)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        let detail = try XCTUnwrap(split.arrangedSubviews.last)
        let bounds = controller.view.bounds
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: controller.view)
        let detailFrame = detail.convert(detail.bounds, to: controller.view)
        XCTAssertEqual(bounds.width, 800, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(sidebarFrame.minX, bounds.minX - 0.5, "sidebar cut off after the drag")
        XCTAssertLessThanOrEqual(detailFrame.maxX, bounds.maxX + 0.5, "detail column cut off after the drag")
        XCTAssertGreaterThanOrEqual(
            detailFrame.maxX - sidebarFrame.maxX, SpotiglassDesign.detailColumnMinWidth - 0.5,
            "detail column squeezed after the drag (sidebar \(sidebarFrame), detail \(detailFrame))"
        )
    }

    /// A window shrunk to 600 pt and widened again in 5 pt steps, the way a window manager sets
    /// sizes from code. The sidebar came back where 280 pt of it would fit next to the detail
    /// column, but it comes back at its 320 pt, so macOS grew the window by the sidebar's width
    /// to make room: 640 pt became 961 (#490). It has to come back inside the width the window
    /// has, and the window keeps every width it's given.
    func testWideningBringsTheSidebarBackWithoutGrowingTheWindowWithSpotify() async throws {
        try await assertWideningKeepsTheWindowWidth(service: .spotify)
    }

    func testWideningBringsTheSidebarBackWithoutGrowingTheWindowWithAppleMusic() async throws {
        try await assertWideningKeepsTheWindowWidth(service: .appleMusic)
    }

    private func assertWideningKeepsTheWindowWidth(service: MusicService) async throws {
        let (controller, window, sampler) = try await hostBrowser(service: service, likeTheAppsWindow: true)
        let widths: [CGFloat] = [600] + stride(from: 605, through: 760, by: 5).map { CGFloat($0) }
        var cameBackAt: CGFloat?
        for width in widths {
            window.setContentSize(CGSize(width: width, height: 600))
            controller.view.layoutSubtreeIfNeeded()
            Self.waitForCommittedWidth(width, sampler)
            // The browser decides at the commit; the split view shows it a layout pass later.
            Self.waitForSidebarToShowDecision(at: width, in: controller, sampler)

            XCTAssertEqual(
                window.contentLayoutRect.width, width, accuracy: 0.5,
                "the window grew by itself after the test set it to \(width) pt"
            )
            let split = try XCTUnwrap(Self.splitView(in: controller.view), "no split view at \(width) pt")
            guard let sidebar = split.arrangedSubviews.first else { continue }
            let collapsed = Self.isCollapsed(sidebar, in: split)
            if width == 600 {
                XCTAssertTrue(collapsed, "the sidebar didn't collapse at 600 pt")
            }
            guard !collapsed else { continue }
            if cameBackAt == nil { cameBackAt = width }
            // Back inside the window it has, next to the detail column at its minimum. Where it
            // doesn't fit, a real window grows by itself to make room.
            let sidebarFrame = sidebar.convert(sidebar.bounds, to: controller.view)
            let bounds = controller.view.bounds
            XCTAssertGreaterThanOrEqual(
                sidebarFrame.minX, bounds.minX - 0.5, "the sidebar runs past the window at \(width) pt (\(sidebarFrame))"
            )
            XCTAssertLessThanOrEqual(
                sidebarFrame.maxX + SpotiglassDesign.detailColumnMinWidth, bounds.maxX + 0.5,
                "no room for the detail column next to the sidebar at \(width) pt (sidebar \(sidebarFrame))"
            )
        }
        XCTAssertNotNil(cameBackAt, "the sidebar never came back up to 760 pt")
    }

    /// Waits until the browser has committed the width the window ends on, directly or by the
    /// trailing commit's run loop timer, however late a busy machine fires it (#510).
    private static func waitForCommittedWidth(
        _ width: CGFloat,
        _ sampler: BrowserWidthSampler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let committed = AppKitTestSupport.pumpRunLoop(until: {
            abs(sampler.latestWidth - width) < 0.5 && sampler.trailingCommit == nil
        })
        XCTAssertTrue(committed, "the browser never committed \(width) pt (latest \(sampler.latestWidth))", file: file, line: line)
    }

    /// Waits until the split view shows what the browser decided for the committed width:
    /// the sidebar collapsed below the width where it fits next to the detail column, and shown
    /// at or above it. Waiting for that instead of for a fixed time reads every width at the
    /// layout it ends on, however late a busy machine gets to the next pass.
    private static func waitForSidebarToShowDecision(
        at width: CGFloat,
        in controller: NSHostingController<AnyView>,
        _ sampler: BrowserWidthSampler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let shouldShow = !BrowserWidthCommitPolicy.mutualExclusionWidth(
            for: sampler.committedWidth,
            comfortableMinWidth: SpotiglassDesign.playlistSidebarAndDetailMinWidth(
                sidebarWidth: sampler.playlistSidebarWidth
            )
        )
        let shown = AppKitTestSupport.pumpRunLoop(until: {
            controller.view.layoutSubtreeIfNeeded()
            guard let split = splitView(in: controller.view), let sidebar = split.arrangedSubviews.first
            else { return false }
            return isCollapsed(sidebar, in: split) != shouldShow
        })
        XCTAssertTrue(
            shown, "the sidebar never \(shouldShow ? "came back" : "collapsed") at \(width) pt", file: file, line: line
        )
    }

    private static func isCollapsed(_ sidebar: NSView, in split: NSSplitView) -> Bool {
        split.isSubviewCollapsed(sidebar) || sidebar.isHidden || sidebar.frame.width < 1
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 2 { return split }
        for subview in view.subviews {
            if let found = splitView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class NarrowWindowTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "narrow-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "narrow-token" }
    func accessToken() async throws -> String { "narrow-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "narrow-token" }
}
