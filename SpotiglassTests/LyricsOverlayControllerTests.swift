import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class LyricsOverlayControllerTests: XCTestCase {
    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.tearDown()
    }

    func testAttachDetachAndDismiss() async {
        let controller = LyricsOverlayController()
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }

        controller.attach(
            playback: playback,
            queue: queue,
            lyrics: lyrics,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        XCTAssertNotNil(controller.playbackViewModel)
        XCTAssertNotNil(controller.queueViewModel)
        XCTAssertNotNil(controller.lyricsModel)

        controller.isPresented = true
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertNotNil(controller.playbackViewModel)

        controller.detach()
        XCTAssertNil(controller.playbackViewModel)
        XCTAssertNil(controller.queueViewModel)
        XCTAssertNil(controller.lyricsModel)
        XCTAssertFalse(controller.isPresented)
    }

    func testLyricsFocusContainerRestoresTheResponderOnDismiss() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let previousResponder = LyricsTestFirstResponderView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        root.addSubview(previousResponder)

        let focusContainer = LyricsOverlayFocusContainerView(
            content: Text("Lyrics"),
            isActive: false
        )
        focusContainer.frame = root.bounds
        focusContainer.autoresizingMask = [.width, .height]
        root.addSubview(focusContainer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            focusContainer.deactivate()
            window.makeFirstResponder(nil)
            window.close()
        }

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(previousResponder, in: window))
        focusContainer.setActive(true)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(
            window.firstResponder === focusContainer,
            "expected lyrics focus, got \(String(describing: window.firstResponder))"
        )

        let space = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        )!
        XCTAssertTrue(focusContainer.ownsKeyEvent(space))
        XCTAssertFalse(focusContainer.ownsKeyEvent(escape))
        focusContainer.keyDown(with: space)
        XCTAssertTrue(focusContainer.performKeyEquivalent(with: space))
        XCTAssertFalse(focusContainer.performKeyEquivalent(with: escape))

        focusContainer.setActive(false)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(
            window.firstResponder === previousResponder,
            "expected restored focus, got \(String(describing: window.firstResponder))"
        )
    }

    func testLyricsFocusContainerRepresentableLifecycle() {
        let wrapper = LyricsOverlayFocusContainer(content: Text("Lyrics"), isActive: false)
        _ = ViewTestHost.host(wrapper, size: CGSize(width: 160, height: 80))
        ViewTestHost.tearDownAll()
    }

    func testDetachingOneSceneLeavesAnotherSceneOverlayAttached() {
        let first = LyricsOverlayController()
        let second = LyricsOverlayController()

        let firstAPI = MockPlaybackAPI()
        let firstPlayback = PlaybackSessionViewModel(
            playbackAPI: firstAPI,
            webCommander: MockWebPlaybackCommander()
        )
        let firstQueue = QueueViewModel(
            playbackAPI: firstAPI,
            playbackSession: firstPlayback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        first.attach(
            playback: firstPlayback,
            queue: firstQueue,
            lyrics: ImmersiveLyricsViewModel { _ in .instrumental },
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )

        let secondAPI = MockPlaybackAPI()
        let secondPlayback = PlaybackSessionViewModel(
            playbackAPI: secondAPI,
            webCommander: MockWebPlaybackCommander()
        )
        let secondQueue = QueueViewModel(
            playbackAPI: secondAPI,
            playbackSession: secondPlayback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        second.attach(
            playback: secondPlayback,
            queue: secondQueue,
            lyrics: ImmersiveLyricsViewModel { _ in .instrumental },
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        first.isPresented = true
        second.isPresented = true

        first.detach()

        XCTAssertFalse(first.isPresented)
        XCTAssertTrue(second.isPresented)
        XCTAssertTrue(second.playbackViewModel === secondPlayback)
        XCTAssertTrue(second.queueViewModel === secondQueue)
        XCTAssertNotNil(second.lyricsModel)
    }
}

@MainActor
private final class LyricsTestFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
