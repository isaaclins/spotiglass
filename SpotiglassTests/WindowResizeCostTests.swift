import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// A window manager (Hammerspoon's `setFrame`, Rectangle, Magnet) resizes the window from code and
/// waits for every size it sets. Each size change made AppKit save the window frame to the app's
/// defaults, and the queue flag in `@AppStorage` re-ran the whole browser for every such write: its
/// sidebar, its page, its player bar and its toolbar, about 70 ms a step in a Release build where
/// Finder takes 15 (#473). A resize must only lay the window out again.
@MainActor
final class WindowResizeCostTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.appStorageDefaults.removeObject(forKey: Self.frameKey)
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// Where AppKit saves a window's frame, here in the store the hosted views' `@AppStorage` reads.
    private static let frameKey = "NSWindow Frame SpotiglassTests.resize"

    private func hostBrowserOnABigPlaylist() async throws -> NSWindow {
        let tracks = (0..<500).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") }
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Big"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
            ])],
            trackResults: ["p1": [.success(tracks)]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        await browserVM.selectPlaylist(id: "p1")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(browserVM.detailState).count, tracks.count)

        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = ResizeTestTokenProvider()
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: SpotiglassPlaybackHost(tokenProvider: tokens),
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_400, height: 900))
        let window = try XCTUnwrap(controller.view.window)
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        window.setContentSize(NSSize(width: 1_450, height: 900))
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        return window
    }

    /// One step of a window manager's animated resize: the new size, then the frame AppKit saves.
    private func resize(_ window: NSWindow, toWidth width: CGFloat, height: CGFloat) {
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
        ViewTestHost.appStorageDefaults.set(window.frameDescriptor, forKey: Self.frameKey)
        // About the pace of Hammerspoon's 0.2 s animation in 12 steps.
        AppKitTestSupport.pumpRunLoop(for: 0.02)
    }

    func testAnAnimatedResizeFromCodeDoesNotReRenderTheBrowser() async throws {
        let window = try await hostBrowserOnABigPlaylist()

        // Wide to narrow and back, all of it wider than the narrowest breakpoint, so no panel
        // opens or closes and nothing on screen changes but the layout.
        let comfortable = SpotiglassDesign.dualSidebarComfortableMinWidth
        let steps = 12
        let widths = (1...steps).map { 1_400 - (1_400 - (comfortable + 40)) * CGFloat($0) / CGFloat(steps) }
        ViewBodyTally.counts = [:]
        for (step, width) in (widths + widths.reversed()).enumerated() {
            resize(window, toWidth: width, height: 900 - CGFloat(step % steps) * 10)
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        let counts = ViewBodyTally.counts ?? [:]

        for container in [
            "PlaylistBrowserView",
            "PlaylistBrowserSidebar",
            "PlaylistsSidebarSectionContent",
            "PlaylistBrowserMainDetailColumn",
            "PlaylistDetailContent",
        ] {
            XCTAssertNil(
                counts[container],
                "\(container) re-rendered \(counts[container] ?? 0) times in \(steps * 2) resize steps"
            )
        }
    }

    /// The flag behind the queue panel tells its views about its own changes only.
    func testTheQueueFlagPublishesOnlyARealChange() {
        let defaults = makeEphemeralDefaults()
        let flag = StoredFlag(key: "queue.panel.visible", defaultValue: false, defaults: defaults)
        var changes = 0
        let subscription = flag.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        defaults.set("0 0 1400 900 0 0 1920 1080 ", forKey: Self.frameKey)
        flag.isOn = false
        XCTAssertEqual(changes, 0, "a write to another key, or of the same value, is no change")

        flag.isOn = true
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(defaults.object(forKey: "queue.panel.visible") as? Bool, true)
        XCTAssertTrue(
            StoredFlag(key: "queue.panel.visible", defaultValue: false, defaults: defaults).isOn,
            "a new window reads what the last one saved"
        )
    }
}

@MainActor
private final class ResizeTestTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "resize-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "resize-token" }
    func accessToken() async throws -> String { "resize-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "resize-token" }
}
