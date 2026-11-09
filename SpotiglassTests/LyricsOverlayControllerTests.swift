import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class LyricsOverlayControllerTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        super.tearDown()
    }

    func testAttachDetachAndDismiss() async {
        let controller = LyricsOverlayController()
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
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

        let keymapStore = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let focusContainer = LyricsOverlayFocusContainerView(
            content: Text("Lyrics"),
            isActive: false,
            keymapStore: keymapStore
        )
        focusContainer.frame = root.bounds
        focusContainer.autoresizingMask = [.width, .height]
        root.addSubview(focusContainer)

        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            focusContainer.deactivate()
            AppKitTestSupport.closeWindowSafely(window)
        }

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(previousResponder, in: window))
        focusContainer.setActive(true)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(
            window.firstResponder === focusContainer,
            "expected lyrics focus, got \(String(describing: window.firstResponder))"
        )

        let lyricsToggle = keyDown(
            keyCode: 37,
            characters: "l",
            modifiers: [.option, .command],
            windowNumber: window.windowNumber
        )
        let space = keyDown(
            keyCode: 49,
            characters: " ",
            windowNumber: window.windowNumber
        )
        let commandPalette = keyDown(
            keyCode: 40,
            characters: "k",
            modifiers: [.command],
            windowNumber: window.windowNumber
        )
        let escape = keyDown(
            keyCode: 53,
            windowNumber: window.windowNumber
        )
        let plainX = keyDown(
            keyCode: 7,
            characters: "x",
            windowNumber: window.windowNumber
        )

        XCTAssertFalse(focusContainer.ownsKeyEvent(lyricsToggle))
        XCTAssertFalse(focusContainer.ownsKeyEvent(space))
        XCTAssertFalse(focusContainer.ownsKeyEvent(commandPalette))
        XCTAssertFalse(focusContainer.ownsKeyEvent(escape))
        XCTAssertTrue(focusContainer.ownsKeyEvent(plainX))
        focusContainer.keyDown(with: plainX)
        XCTAssertFalse(focusContainer.performKeyEquivalent(with: lyricsToggle))
        XCTAssertFalse(focusContainer.performKeyEquivalent(with: space))
        XCTAssertFalse(focusContainer.performKeyEquivalent(with: commandPalette))
        XCTAssertFalse(focusContainer.performKeyEquivalent(with: escape))
        XCTAssertTrue(focusContainer.performKeyEquivalent(with: plainX))

        focusContainer.setActive(false)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(
            window.firstResponder === previousResponder,
            "expected restored focus, got \(String(describing: window.firstResponder))"
        )
    }

    /// #438: opening the lyrics left the keyboard on the invisible container around them, so
    /// the arrow and page keys did nothing until Tab was pressed. The lyrics list now takes
    /// focus once it is laid out. Hosts the real list (`ImmersiveLyricsScrollCore`) with the
    /// same focus request `ImmersiveLyricsView` makes, in the real focus container.
    func testOpeningTheLyricsPutsFocusOnTheLyricsList() throws {
        let box = FocusProbeBox()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let previousResponder = LyricsTestFirstResponderView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        root.addSubview(previousResponder)
        let focusContainer = LyricsOverlayFocusContainerView(
            content: FocusProbeLyrics(box: box),
            isActive: false,
            keymapStore: CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        )
        focusContainer.frame = root.bounds
        root.addSubview(focusContainer)
        let window = OffscreenTestWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            focusContainer.deactivate()
            AppKitTestSupport.closeWindowSafely(window)
        }

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(previousResponder, in: window))
        focusContainer.setActive(true)
        AppKitTestSupport.pumpRunLoop(for: 1.2)

        XCTAssertTrue(box.focused, "the lyrics list does not have the keyboard after opening")
        let responder = try XCTUnwrap(window.firstResponder as? NSView, "nothing has the keyboard")
        XCTAssertTrue(responder.isDescendant(of: focusContainer), "focus is outside the lyrics: \(responder)")

        focusContainer.setActive(false)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(window.firstResponder === previousResponder, "closing the lyrics did not give focus back")
    }

    func testLyricsFocusContainerRepresentableLifecycle() {
        let wrapper = LyricsOverlayFocusContainer(
            content: Text("Lyrics"),
            isActive: true,
            keymapStore: CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        )
        let controller = ViewTestHost.host(wrapper, size: CGSize(width: 160, height: 80))
        XCTAssertTrue(controller.view.window?.firstResponder is LyricsOverlayFocusContainerView<Text>)
        ViewTestHost.tearDownAll()
    }

    func testLyricsFocusContainerDismantlesAnActiveView() {
        let keymapStore = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let view = LyricsOverlayFocusContainerView(
            content: Text("Lyrics"),
            isActive: true,
            keymapStore: keymapStore
        )

        LyricsOverlayFocusContainer<Text>.dismantleNSView(view, coordinator: ())
    }

    func testDetachingOneSceneLeavesAnotherSceneOverlayAttached() {
        let first = LyricsOverlayController()
        let second = LyricsOverlayController()

        let firstAPI = MockPlaybackAPI()
        let firstPlayback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: firstAPI, webCommander: MockWebPlaybackCommander()))
        let firstQueue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: firstAPI),
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
            provider: SpotifyPlaybackProvider(playbackAPI: secondAPI, webCommander: MockWebPlaybackCommander()))
        let secondQueue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: secondAPI),
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

final class FocusProbeBox { var focused = false }

/// The real lyrics list with the focus request `ImmersiveLyricsView` makes on opening.
private struct FocusProbeLyrics: View {
    let box: FocusProbeBox
    @FocusState private var focused: Bool

    var body: some View {
        ImmersiveLyricsScrollCore(activeID: 0, reduceMotion: true, usesLyricsScrollEdgeFade: false) { _ in
            VStack { ForEach(0..<40) { Text("Line \($0)").id($0) } }
        }
        .environment(\.lyricsListFocus, $focused)
        .onChange(of: focused) { _, new in box.focused = new }
        .task {
            for delay in [0, 150, 400, 800] {
                try? await Task.sleep(for: .milliseconds(delay))
                if focused { return }
                focused = true
            }
        }
    }
}
