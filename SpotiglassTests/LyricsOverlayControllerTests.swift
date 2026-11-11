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

    /// #438: the sidebar and the queue stay usable next to the lyrics. Clicking a sidebar row
    /// (which also closes the lyrics) or pressing Escape in the queue put the keyboard back on
    /// whatever had it before the lyrics opened, so the arrows stopped moving in the sidebar.
    /// With the keyboard moved out, the lyrics also stop claiming shortcuts, and they never
    /// claim ⌘ shortcuts, which belong to the menu bar (Repeat ⌥⌘R, seeking).
    func testKeyboardMovedOutOfTheLyricsStaysWhereTheUserPutIt() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let previousResponder = LyricsTestFirstResponderView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        let sidebar = LyricsTestFirstResponderView(frame: NSRect(x: 0, y: 40, width: 100, height: 32))
        root.addSubview(previousResponder)
        root.addSubview(sidebar)
        let keymapStore = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let focusContainer = LyricsOverlayFocusContainerView(
            content: Text("Lyrics"),
            isActive: false,
            keymapStore: keymapStore
        )
        focusContainer.frame = NSRect(x: 120, y: 0, width: 200, height: 240)
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
        XCTAssertTrue(focusContainer.hasKeyboardFocus)
        XCTAssertFalse(focusContainer.keyboardFocusMovedAway)

        let plainX = keyDown(keyCode: 7, characters: "x", windowNumber: window.windowNumber)
        let repeatShortcut = keyDown(
            keyCode: 15,
            characters: "r",
            modifiers: [.option, .command],
            windowNumber: window.windowNumber
        )
        XCTAssertTrue(focusContainer.performKeyEquivalent(with: plainX))
        XCTAssertFalse(
            focusContainer.performKeyEquivalent(with: repeatShortcut),
            "the lyrics swallowed ⌥⌘R before the menu bar saw it"
        )

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(sidebar, in: window))
        XCTAssertTrue(focusContainer.keyboardFocusMovedAway)
        XCTAssertFalse(
            focusContainer.performKeyEquivalent(with: plainX),
            "the lyrics claimed a key while the keyboard was in the sidebar"
        )

        focusContainer.setActive(false)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(
            window.firstResponder === sidebar,
            "closing the lyrics moved the keyboard out of the sidebar to \(String(describing: window.firstResponder))"
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
        // The focus request retries on its own timer (up to 1.35 s in): wait until it is done,
        // however late a busy machine runs it, not for a fixed time (#510).
        AppKitTestSupport.pumpRunLoop(until: { box.requestFinished })

        XCTAssertTrue(box.focused, "the lyrics list does not have the keyboard after opening")
        let responder = try XCTUnwrap(window.firstResponder as? NSView, "nothing has the keyboard")
        XCTAssertTrue(responder.isDescendant(of: focusContainer), "focus is outside the lyrics: \(responder)")

        focusContainer.setActive(false)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(window.firstResponder === previousResponder, "closing the lyrics did not give focus back")
    }

    /// #438: lyrics that finish loading after the user clicked into the sidebar must not take
    /// the keyboard from there.
    func testListFocusIsNotTakenBackAfterTheUserMovedIt() async {
        var focusRequests = 0
        await ImmersiveLyricsView.requestListFocus(
            isFocused: { false },
            movedAway: { true },
            focus: { focusRequests += 1 }
        )
        XCTAssertEqual(focusRequests, 0, "the lyrics took the keyboard back from the sidebar")
    }

    /// #438: without a lyrics list (loading, instrumental, no lyrics) the container has the
    /// keyboard, and Tab must move on to the sidebar, the queue and the player bar next to it.
    func testTabLeavesTheLyricsContainer() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let sidebar = LyricsTestFirstResponderView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        root.addSubview(sidebar)
        let focusContainer = LyricsOverlayFocusContainerView(
            content: Text("Loading"),
            isActive: false,
            keymapStore: CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        )
        focusContainer.frame = NSRect(x: 120, y: 0, width: 200, height: 240)
        root.addSubview(focusContainer)
        focusContainer.nextKeyView = sidebar
        sidebar.nextKeyView = focusContainer
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

        focusContainer.setActive(true)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(window.firstResponder === focusContainer)
        focusContainer.keyDown(with: keyDown(keyCode: 48, characters: "\t", windowNumber: window.windowNumber))
        XCTAssertTrue(
            window.firstResponder === sidebar,
            "Tab stayed in the lyrics: \(String(describing: window.firstResponder))"
        )
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

final class FocusProbeBox {
    var focused = false
    /// The focus request stopped retrying.
    var requestFinished = false
}

/// The real lyrics list with the real focus request `ImmersiveLyricsView` makes on opening.
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
            await ImmersiveLyricsView.requestListFocus(
                isFocused: { focused },
                movedAway: { false },
                focus: { focused = true }
            )
            box.requestFinished = true
        }
    }
}
