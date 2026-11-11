import AppKit
import ApplicationServices
import CoreAudio
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testScrubberViewExposesAccessibilityProgress() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let view = ScrubberView(
            progress: ScrubberProgress(
                anchor: PlaybackProgressAnchor(
                    positionMilliseconds: 75_600,
                    anchorDate: Date(),
                    durationMilliseconds: 180_000,
                    isAdvancing: false
                ),
                durationMilliseconds: 180_000
            ),
            onSeek: { _ in },
            onDragUpdate: { _ in }
        )
        .frame(width: 280, height: 24)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 48))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityLabel: "Playback progress"))
    }

    /// The times are drawn in a canvas, so they are checked through the same
    /// functions the canvas draws from.
    func testPlaybackProgressScrubberGroupStaticLabels() {
        let progress = ScrubberProgress(
            anchor: PlaybackProgressAnchor(
                positionMilliseconds: 90_000,
                anchorDate: Date(),
                durationMilliseconds: 180_000,
                isAdvancing: false
            ),
            durationMilliseconds: 180_000
        )
        let positionMs = progress.positionMilliseconds(at: Date().addingTimeInterval(30))
        XCTAssertEqual(PlaybackProgressScrubberGroup.elapsedText(positionMs: positionMs), "1:30")
        XCTAssertEqual(
            PlaybackProgressScrubberGroup.remainingText(positionMs: positionMs, durationMs: progress.durationMilliseconds),
            "−1:30"
        )
    }

    func testPlaybackControlsDisconnectedState() throws {
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback disconnected"))
    }

    func testPlaybackControlsPlayingShowsTrackTitleAndLyricsControl() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = makePlayingPlayback()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Midnight City"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Lyrics"))
    }

    /// The bug (#355) was a near-transparent overlay swallowing clicks before
    /// they reached the native button. The guard is an alpha assertion, not a
    /// synthesized event: synthetic `NSEvent`s need a real key window on screen
    /// and never land on a headless CI runner.
    func testPlaybackLyricsTransportButtonsAreClickable() throws {
        let playback = makePlayingPlayback()
        var isPresented = false
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: Binding(
                get: { isPresented },
                set: { isPresented = $0 }
            ),
            openArtist: { _ in }
        )

        let controller = ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        let buttons = allNSButtons(in: controller.view)
        let lyricsButton = try XCTUnwrap(
            buttons.first {
                $0.accessibilityLabel() == SpotiglassL10n.string("playback.controls.lyrics")
            },
            "The hosted transport did not expose its Lyrics button"
        )
        let artworkLyricsButton = try XCTUnwrap(
            buttons.first {
                $0.accessibilityLabel() == SpotiglassL10n.string("playback.controls.openLyrics")
            },
            "The hosted transport did not expose its Open lyrics button"
        )
        XCTAssertTrue(lyricsButton.isEnabled)
        XCTAssertTrue(artworkLyricsButton.isEnabled)

        assertNothingFadesOut(lyricsButton, upTo: controller.view, named: "Lyrics")
        assertNothingFadesOut(artworkLyricsButton, upTo: controller.view, named: "Open lyrics")

        lyricsButton.performClick(nil)
        XCTAssertTrue(isPresented, "The Lyrics transport button is not wired to the lyrics binding")

        isPresented = false
        artworkLyricsButton.performClick(nil)
        XCTAssertTrue(isPresented, "The artwork lyrics button is not wired to the lyrics binding")
    }

    /// #438: the player bar stays under the open lyrics. Its Lyrics button set them open and
    /// nothing else, so with the lyrics open a click did nothing and the tooltip still said
    /// "Show lyrics". It toggles now and says it closes them.
    func testPlayerBarLyricsButtonClosesOpenLyrics() throws {
        let playback = makePlayingPlayback()
        var isPresented = true
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: Binding(
                get: { isPresented },
                set: { isPresented = $0 }
            ),
            openArtist: { _ in }
        )
        XCTAssertEqual(view.lyricsButtonTooltip, SpotiglassL10n.string("browser.closeLyrics"))

        let controller = ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        let buttons = allNSButtons(in: controller.view)
        let lyricsButton = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel() == SpotiglassL10n.string("playback.controls.lyrics") }
        )
        let artworkButton = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel() == SpotiglassL10n.string("browser.closeLyrics") },
            "with the lyrics open the cover button still offers to open them"
        )
        lyricsButton.performClick(nil)
        XCTAssertFalse(isPresented, "the bar's Lyrics button doesn't close open lyrics")

        isPresented = true
        artworkButton.performClick(nil)
        XCTAssertFalse(isPresented, "the cover button doesn't close open lyrics")
    }

    /// Asserts no ancestor of the button is faded out. `hitTest` cannot answer
    /// this: `NSHostingView` reports itself for every point and never a nested
    /// bridged control. Alpha is the mechanism that broke #355, and a view with
    /// an alpha below 1 stops receiving mouse events through the bridge even
    /// though it still draws and still answers accessibility queries.
    private func assertNothingFadesOut(
        _ button: NSButton,
        upTo root: NSView,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var ancestor: NSView? = button
        while let view = ancestor, view !== root {
            XCTAssertEqual(
                view.alphaValue,
                1,
                "\(name) sits under a faded view (\(type(of: view))), which stops mouse delivery",
                file: file,
                line: line
            )
            ancestor = view.superview
        }
    }

    func testPlaybackControlsConnectingState() throws {
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.start()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Connecting Spotify playback..."))
    }

    func testPlaybackControlsInitializationErrorShowsReconnect() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.handle(.initializationError("Web Playback failed to load"))
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback could not start"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Reconnect playback"))
    }

    func testPlaybackControlsPlaybackErrorShowsRetry() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.handle(.playbackError("No active device"))
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback error"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Retry playback transfer"))
    }

    func testPlaybackControlsDisablesRepeatUntilTransportStateKnown() async throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let api = MockPlaybackAPI()
        api.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        await playback.syncTransportFromSpotify()

        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))

        let repeatButton = try view.inspect().find(viewWithAccessibilityLabel: "Repeat off")
        XCTAssertTrue(repeatButton.isDisabled())
    }

    func testPlaybackControlsReadyShowsTransportAccessibility() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.repeatMode = .context
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Ready to play"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Previous track"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Repeat playlist"))
    }

    func testRealizedTransportAccessibilityTreeExposesLabeledControls() throws {
        let playback = makePlayingPlayback(artists: ["M83", "The Weeknd"])
        let playbackHost = SpotiglassPlaybackHost(
            tokenProvider: MockPlaybackTokenProvider(
                accessToken: "a",
                refreshedAccessToken: "b"
            )
        )
        let view = ZStack {
            PlaybackControlsView(
                viewModel: playback,
                isLyricsPresented: .constant(false),
                openArtist: { _ in }
            )
            SpotiglassPlaybackHostView(host: playbackHost)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }

        let controller = ViewTestHost.host(view, size: CGSize(width: 700, height: 500))
        let window = try XCTUnwrap(controller.view.window)
        window.title = "AXTestTransport"
        window.makeKeyAndOrderFront(nil)
        AppKitTestSupport.pumpRunLoop(for: 0.5)

        guard let elements = realizedAccessibilityTreeIfAvailable(in: window) else {
            throw XCTSkip(
                "Skipped because the hosted window has no realised accessibility tree in this environment."
            )
        }
        let treeDump = realizedAccessibilityTreeDescription(elements)
        let transportElements = try XCTUnwrap(
            realizedAccessibilitySubtree(containingAccessibilityDescription: "Playback progress", in: elements),
            "Could not isolate the realised transport subtree.\nRealised accessibility tree:\n\(treeDump)"
        )
        let interactiveElements = transportElements.filter(\.isInteractiveTransportControl)
        let unlabeledElements = interactiveElements.filter { !$0.hasMeaningfulAccessibilityLabel }
        XCTAssertFalse(
            interactiveElements.isEmpty,
            "Expected the realised accessibility tree to expose interactive transport controls.\nRealised accessibility tree:\n\(treeDump)"
        )
        XCTAssertTrue(
            unlabeledElements.isEmpty,
            "Expected every realised interactive transport control to expose a non-empty, non-generic label; got \(unlabeledElements).\nRealised accessibility tree:\n\(treeDump)"
        )
        XCTAssertFalse(
            elements.contains { $0.role == "AXWebArea" },
            "The realised accessibility tree must not contain AXWebArea.\nRealised accessibility tree:\n\(treeDump)"
        )
        XCTAssertFalse(
            elements.contains { $0.role == "AXStaticText" && $0.value == ", " },
            "The realised accessibility tree must not expose the artist separator as static text.\nRealised accessibility tree:\n\(treeDump)"
        )
    }

    /// The bar keeps one scrubber in every arrangement (#394). It used to pick
    /// its arrangement with a `ViewThatFits` over three complete copies of the
    /// transport; in the app that rebuilt the scrubber on layout passes and the
    /// new scrubber's timeline asked for the next pass, which kept a CPU core
    /// busy (measured in Release builds; a test window does not loop). A press
    /// survives a player update and the window passing the volume's switch from
    /// slider to button and back, and the release seeks once, at the pointer.
    func testPressOnTheBarSurvivesUpdatesAndRearrangement() throws {
        let api = MockPlaybackAPI()
        let sentSeeks = SentSeeks()
        api.onSeekAttempt = { sentSeeks.append($0) }
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(Self.midnightCity(), isPaused: false, nextTracks: []))

        let controller = NSHostingController(
            rootView: PlaybackControlsView(
                viewModel: playback,
                isLyricsPresented: .constant(false),
                openArtist: { _ in }
            )
        )
        controller.sizingOptions = [.minSize]
        // A one-row width and a two-row width that fit small CI screens too.
        let rowSize = NSSize(width: 880, height: 120)
        let stackedSize = NSSize(width: 640, height: 120)
        let window = KeyTestPanel(
            contentRect: NSRect(origin: .zero, size: rowSize),
            styleMask: [.titled, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "AXTestTransportClick"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(rowSize)
        window.orderFrontRegardless()
        window.makeKey()
        defer { AppKitTestSupport.closeWindowSafely(window) }
        AppKitTestSupport.pumpRunLoop(for: 0.5)

        // AX frames are in screen points from the top of the main screen.
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        func scrubberFrameOnScreen() throws -> NSRect {
            let scrubber = try XCTUnwrap(
                try realizedAccessibilityTree(in: window).first { $0.axDescription == "Playback progress" }
            )
            let position = try XCTUnwrap(scrubber.position)
            let size = try XCTUnwrap(scrubber.size)
            return NSRect(x: position.x, y: screenHeight - position.y - size.height, width: size.width, height: size.height)
        }
        let bar = try scrubberFrameOnScreen()
        let location = window.convertPoint(fromScreen: NSPoint(x: bar.minX + bar.width * 0.75, y: bar.midY))

        func send(_ type: NSEvent.EventType) {
            window.sendEvent(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!)
        }
        send(.leftMouseDown)
        AppKitTestSupport.pumpRunLoop(for: 0.15)
        playback.handle(.stateChanged(Self.midnightCity(positionMilliseconds: 32_000), isPaused: false, nextTracks: []))
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        window.setContentSize(stackedSize)
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        window.setContentSize(rowSize)
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        // Where the pointer now sits on the bar, should the window not have
        // got its size back exactly.
        let barAtRelease = try scrubberFrameOnScreen()
        let pointer = window.convertPoint(toScreen: location)
        let fraction = min(max((pointer.x - barAtRelease.minX) / barAtRelease.width, 0), 1)
        send(.leftMouseUp)
        AppKitTestSupport.pumpRunLoop(for: 0.5)

        let seeks = sentSeeks.values
        XCTAssertEqual(seeks.count, 1, "the click must seek once; window \(window.frame), bar \(bar) then \(barAtRelease)")
        if let seek = seeks.first {
            XCTAssertEqual(Double(seek), Double(fraction) * 240_000, accuracy: 4_000, "the seek lands where the pointer is")
        }
    }

    /// VoiceOver moves through the bar in the order it is laid out on screen:
    /// the song, then the buttons from Lyrics to Repeat, then the device menu
    /// and the volume, and the scrubber under them last.
    func testVoiceOverReadsTheScrubberWhereItSits() throws {
        for width in [CGFloat(640), 1_100] {
            let controller = NSHostingController(
                rootView: PlaybackControlsView(
                    viewModel: makePlayingPlayback(),
                    isLyricsPresented: .constant(false),
                    openArtist: { _ in }
                )
            )
            let window = OffscreenTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "AXTestOrder\(Int(width))"
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: width, height: 140))
            window.orderFrontRegardless()
            defer { AppKitTestSupport.closeWindowSafely(window) }
            AppKitTestSupport.pumpRunLoop(for: 0.4)

            let order = try voiceOverOrder(in: window)
            let scrubber = try XCTUnwrap(order.firstIndex(of: "Playback progress"), "\(order)")
            let lyrics = try XCTUnwrap(order.firstIndex(of: SpotiglassL10n.string("playback.controls.lyrics")), "\(order)")
            let previous = try XCTUnwrap(order.firstIndex(of: SpotiglassL10n.string("playback.controls.previous")), "\(order)")
            let next = try XCTUnwrap(order.firstIndex(of: "Next track"), "\(order)")
            XCTAssertLessThan(lyrics, previous, "Lyrics comes before Previous at \(width): \(order)")
            XCTAssertLessThan(previous, next, "at \(width): \(order)")
            XCTAssertGreaterThan(scrubber, next, "at \(width) the scrubber comes after the buttons: \(order)")
        }
    }

    /// The bar in each state that changes its parts: playing (with a title
    /// far too long for the bar), paused, Apple Music (no volume control), the
    /// other service's player (a label instead of Lyrics), no player, and the
    /// Reconnect and Retry buttons.
    private func playerBarStates() async throws -> [(String, () -> PlaybackSessionViewModel)] {
        // Apple Music reads its state from the player, so the scripted
        // MusicKit player really plays the song.
        let appleMusicPlayer = ScriptedAppleMusicPlayer()
        let appleMusicProvider = AppleMusicPlaybackProvider(player: appleMusicPlayer)
        let appleMusic = PlaybackSessionViewModel(provider: appleMusicProvider)
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        try await appleMusicProvider.play(
            .items(uris: ["applemusic:song:midnight"], startURI: nil),
            deviceID: AppleMusicPlaybackProvider.deviceID
        )
        appleMusicPlayer.advance(by: 1)
        appleMusic.setConnectionState(.playing(Self.midnightCity()))

        return [
            ("playing", { self.makePlayingPlayback() }),
            ("long title", {
                let playback = self.makePlayingPlayback()
                playback.handle(.stateChanged(
                    Self.midnightCity(name: "Midnight City (Live at the Hollywood Bowl, Extended Version With the Full Orchestra)"),
                    isPaused: false,
                    nextTracks: []
                ))
                return playback
            }),
            ("paused", { self.makePlayingPlayback(paused: true) }),
            ("apple music", { appleMusic }),
            ("other service", { self.makePlayingPlayback() }),
            ("disconnected", {
                PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(
                    playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
            }),
            ("reconnect", {
                let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(
                    playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
                playback.handle(.initializationError("Web Playback failed to load"))
                return playback
            }),
            ("retry", {
                let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(
                    playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
                playback.handle(.playbackError("No active device"))
                return playback
            }),
        ]
    }

    /// Lays the real bar out in an offscreen window `width` points wide and
    /// hands its accessibility tree to `check`, with the window's title.
    private func withPlayerBar(
        state: String,
        playback: PlaybackSessionViewModel,
        width: CGFloat,
        appearance: NSAppearance.Name,
        check: (_ elements: [RealizedAccessibilityElement], _ window: NSWindow) throws -> Void
    ) throws {
        let controller = NSHostingController(
            rootView: PlaybackControlsView(
                viewModel: playback,
                isLyricsPresented: .constant(false),
                openArtist: { _ in },
                otherService: state == "other service" ? .appleMusic : nil
            )
        )
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: width, height: 160))
        defer { AppKitTestSupport.closeWindowSafely(window) }
        window.title = "AXTestPlayerBar-\(state)-\(appearance.rawValue)-\(Int(width))"
        window.orderFrontRegardless()
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        try check(try realizedAccessibilityTree(in: window), window)
    }

    /// The scrubber's row as the bar lays it out: its height, and how much
    /// wider it is than the scrubber, the times either side and their gaps.
    /// VoiceOver doesn't see the times, so the row is laid out on its own.
    private func measuredScrubberRow() throws -> (height: CGFloat, overhead: CGFloat) {
        let rowWidth: CGFloat = 400
        let host = NSHostingView(rootView: PlaybackProgressScrubberGroup(
            progressAnchor: nil, durationMilliseconds: 180_000, isEnabled: true, onSeek: { _ in }
        ))
        let height = host.fittingSize.height
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: rowWidth, height: height))
        defer { AppKitTestSupport.closeWindowSafely(window) }
        window.title = "AXTestScrubberRow"
        window.orderFrontRegardless()
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        let progressLabel = SpotiglassL10n.string("playback.scrubber.progress")
        let scrubber = try XCTUnwrap(try realizedAccessibilityTree(in: window).first { $0.axDescription == progressLabel })
        return (height, rowWidth - scrubber.size.width)
    }

    /// Every control the bar shows, by its accessibility frame: the artwork
    /// and Lyrics buttons, Reconnect or Retry, the transport buttons, the
    /// device menu, the volume slider or its button, and the scrubber. The
    /// artist names are links in the artist line under the title, so they are
    /// left out. The times either side of the scrubber are hidden from
    /// VoiceOver; testTimesSitOnTheScrubbersCentreLine checks them.
    private func playerBarControls(in elements: [RealizedAccessibilityElement]) -> [RealizedAccessibilityElement] {
        let progressLabel = SpotiglassL10n.string("playback.scrubber.progress")
        return elements.filter { element in
            guard element.position != nil, element.size.height > 0 else { return false }
            if element.axDescription == progressLabel { return true }
            return ["AXButton", "AXMenuButton", "AXPopUpButton", "AXSlider"].contains(element.role)
                && !element.axDescription.contains("M83") && !element.title.contains("M83")
        }
    }

    /// Play/pause sits on the bar's horizontal centre, with Previous and Next
    /// either side of it and the scrubber centred under them, at every width
    /// from the window's minimum up (#496). The bar spans the window with equal
    /// margins outside the split view, so this is the window's centre with the
    /// sidebar shown or hidden. The controls used to sit at the bar's trailing
    /// end, next to the device menu: play/pause was 82 pt right of the centre
    /// in a 640 pt window and 325 pt right of it at 1400 pt. The song keeps the
    /// left side and truncates, and the device menu and the volume keep the
    /// right one, so nothing overlaps.
    func testPlayPauseSitsOnTheWindowsCentreAtEveryWidth() async throws {
        let previousLabel = SpotiglassL10n.string("playback.controls.previous")
        let nextLabel = SpotiglassL10n.string("playback.controls.next")
        let progressLabel = SpotiglassL10n.string("playback.scrubber.progress")
        for (state, makePlayback) in try await playerBarStates() {
            // The widest line of text before Reconnect or Retry at the last width.
            var recoveryTextWidth: CGFloat = 0
            for width in [CGFloat(520), 640, 760, 880, 900, 1_000, 1_100, 1_400] {
                try withPlayerBar(state: state, playback: makePlayback(), width: width, appearance: .aqua) { elements, window in
                    let controls = playerBarControls(in: elements)
                    func midX(_ element: RealizedAccessibilityElement) -> CGFloat {
                        (element.position?.x ?? 0) + element.size.width / 2
                    }
                    func minX(_ element: RealizedAccessibilityElement) -> CGFloat { element.position?.x ?? 0 }
                    func maxX(_ element: RealizedAccessibilityElement) -> CGFloat { minX(element) + element.size.width }
                    let label = "\(state) at \(Int(width)): \(controls.map { "\($0.axDescription) x \(minX($0))-\(maxX($0))" })"
                    let centre = window.frame.minX + width / 2
                    let previous = try XCTUnwrap(controls.first { $0.axDescription == previousLabel }, label)
                    let next = try XCTUnwrap(controls.first { $0.axDescription == nextLabel }, label)
                    let playPauseIndex = try XCTUnwrap(controls.firstIndex { $0.axDescription == previousLabel }, label) + 1
                    let playPause = controls[playPauseIndex]
                    XCTAssertTrue(
                        [SpotiglassL10n.string("playback.play"), SpotiglassL10n.string("playback.pause")]
                            .contains(playPause.axDescription),
                        "play/pause follows Previous, \(label)"
                    )
                    XCTAssertEqual(midX(playPause), centre, accuracy: 0.5, "play/pause is off the window's centre, \(label)")
                    XCTAssertEqual(centre - midX(previous), midX(next) - centre, accuracy: 0.5, "Previous and Next aren't either side of play/pause, \(label)")
                    let scrubber = try XCTUnwrap(controls.first { $0.axDescription == progressLabel }, label)
                    XCTAssertEqual(midX(scrubber), centre, accuracy: 0.5, "the scrubber isn't under the controls, \(label)")
                    XCTAssertGreaterThanOrEqual(scrubber.size.width, PlaybackTransportLayoutPolicy.scrubberMinimumWidth, label)

                    // The cluster is Lyrics' slot, the three buttons and Repeat,
                    // evenly spaced and symmetric around play/pause.
                    let lyricsSlotMidX = 2 * midX(previous) - midX(playPause)
                    let clusterMinX = lyricsSlotMidX - SpotiglassDesign.Layout.iconButtonSize / 2
                    let clusterMaxX = 2 * centre - clusterMinX
                    for control in controls where control.axDescription != progressLabel {
                        // A button's accessibility frame is its bezel, a point wider than its slot.
                        let isCluster = minX(control) >= clusterMinX - 1.5 && maxX(control) <= clusterMaxX + 1.5
                        if !isCluster {
                            XCTAssertTrue(
                                maxX(control) <= clusterMinX - SpotiglassDesign.spacingS
                                    || minX(control) >= clusterMaxX + SpotiglassDesign.spacingS,
                                "\(control.axDescription) runs into the play controls, \(label)"
                            )
                        }
                    }
                    // The title truncates before the controls: no text reaches them.
                    for text in elements where text.role == "AXStaticText" && text.position != nil && text.value != window.title {
                        if minX(text) < centre {
                            XCTAssertLessThanOrEqual(maxX(text), clusterMinX - SpotiglassDesign.spacingS, "\(text.value) runs into the controls, \(label)")
                        }
                    }
                    // Reconnect and Retry sit right after the line that says what
                    // went wrong, not at the far end of the left half.
                    let recoveryLabels = ["playback.controls.reconnect.label", "playback.controls.retry.label"].map { SpotiglassL10n.string($0) }
                    if let recovery = controls.first(where: { recoveryLabels.contains($0.axDescription) }) {
                        // The status lines: the texts of the bar left of the button.
                        let texts = elements.filter {
                            $0.role == "AXStaticText" && $0.position != nil && $0.value != window.title && minX($0) < minX(recovery)
                        }
                        let textEnd = try XCTUnwrap(
                            texts.map(maxX).max(),
                            "no status text before \(recovery.axDescription), \(label)"
                        )
                        // A truncated line's frame ends at its last glyph, a few points
                        // short of its slot; before the fix the gap was 40 pt and more.
                        XCTAssertLessThanOrEqual(minX(recovery) - textEnd, SpotiglassDesign.spacingM + SpotiglassDesign.spacingXS + 1.5, "\(recovery.axDescription) is far from its text, \(label)")
                        // A wider window never gives that text less room: the button
                        // used to take its title at about 876 pt and cut the message
                        // to a third of what it had at 872 pt.
                        let textWidth = texts.map(\.size.width).max() ?? 0
                        XCTAssertGreaterThanOrEqual(textWidth, recoveryTextWidth - 0.5, "the status text lost room as the window widened, \(label)")
                        recoveryTextWidth = textWidth
                    }
                    // Nothing spills out of the window.
                    for control in controls {
                        XCTAssertGreaterThanOrEqual(minX(control), window.frame.minX - 0.5, "\(control.axDescription), \(label)")
                        XCTAssertLessThanOrEqual(maxX(control), window.frame.maxX + 0.5, "\(control.axDescription), \(label)")
                    }
                }
            }
        }
    }

    /// In every width from the narrowest window up (#496): the title never
    /// loses room as the window widens, Paused shows whole right after it once
    /// the whole title fits beside it (never squeezing the song's name), and
    /// the other service's bar always says which service plays. With the
    /// controls on the centre the left half is narrow: the title used to trade
    /// letters with the badge after it, a later attempt hid "In Apple Music"
    /// below about 665 pt, and the badge drifted to the far end of the left
    /// half, up against the play controls.
    func testTheTitleKeepsItsRoomAndTheBarSaysWhatPlays() async throws {
        let paused = SpotiglassL10n.string("playback.paused.label")
        let service = SpotiglassL10n.format("playback.controls.otherService.label", MusicService.appleMusic.displayName)
        let widths = Array(stride(from: CGFloat(520), through: 760, by: 6)) + [1_000, 1_400]
        // "playing" comes before "paused" in `playerBarStates()`.
        var playingTitleWidths: [CGFloat: CGFloat] = [:]
        for (state, makePlayback) in try await playerBarStates() where ["playing", "paused", "other service"].contains(state) {
            var titleWidth: CGFloat = 0
            var pausedWidth: CGFloat?
            for width in widths {
                try withPlayerBar(state: state, playback: makePlayback(), width: width, appearance: .aqua) { elements, _ in
                    let label = "\(state) at \(Int(width))"
                    let texts = elements.filter { $0.role == "AXStaticText" && $0.position != nil }
                    let title = try XCTUnwrap(texts.first { $0.value == "Midnight City" }, label)
                    // Paused waits until the whole title fits beside it, so not
                    // even its arrival takes room from the title.
                    XCTAssertGreaterThanOrEqual(title.size.width, titleWidth - 0.5, "the title lost room as the window widened, \(label)")
                    titleWidth = title.size.width
                    let titleEnd = (title.position?.x ?? 0) + title.size.width
                    if state == "playing" {
                        playingTitleWidths[width] = title.size.width
                    }
                    if state == "paused" {
                        if let badge = texts.first(where: { $0.value == paused }) {
                            // Paused shows whole, right after a title that keeps its floor.
                            XCTAssertEqual(badge.size.width, pausedWidth ?? badge.size.width, accuracy: 0.5, "Paused is cut short, \(label)")
                            pausedWidth = pausedWidth ?? badge.size.width
                            let wholeTitle = try XCTUnwrap(playingTitleWidths[1_400], label)
                            XCTAssertGreaterThanOrEqual(title.size.width, wholeTitle - 0.5, "Paused cut the title short, \(label)")
                            // A truncated title's frame ends at its last glyph, a few
                            // points short of its slot.
                            XCTAssertLessThanOrEqual((badge.position?.x ?? 0) - titleEnd, SpotiglassDesign.spacingXS + SpotiglassDesign.spacingXS + 0.5, "Paused drifted from the title, \(label)")
                        } else {
                            // Too narrow for both: the title keeps all the room it
                            // has while playing, and Paused waits for a wider bar.
                            XCTAssertNil(pausedWidth, "Paused went away in a wider window, \(label)")
                            let playing = try XCTUnwrap(playingTitleWidths[width], label)
                            XCTAssertGreaterThanOrEqual(title.size.width, playing - 0.5, "the paused title has less room than the playing one, \(label)")
                        }
                    }
                    if state == "other service" {
                        let line = try XCTUnwrap(texts.first { $0.value.hasPrefix(service) }, "the bar doesn't say which service plays, \(label)")
                        XCTAssertLessThanOrEqual(abs((line.position?.x ?? 0) - (title.position?.x ?? 0)), 0.5, "the service doesn't lead the line under the title, \(label)")
                        XCTAssertGreaterThan(line.size.width, title.size.width / 2, "the service line is squeezed, \(label)")
                    }
                }
            }
        }
    }

    /// The bar has two lines to share (#427, #538). The transport buttons,
    /// Lyrics among them, sit on one row with the scrubber under them. Where
    /// the bar has room, the song on the left, Reconnect or Retry, the device
    /// menu and the volume sit on the middle of the bar, the middle of the
    /// buttons and the scrubber taken together, and the scrubber and its times
    /// keep clear of them. Since #504 put the controls in the middle they sat
    /// on the buttons' row instead, up in the top half of the bar with empty
    /// space under them. In a narrow bar the sides join the buttons' row and
    /// the scrubber runs under all of them. The Lyrics button once sat in the
    /// title's text row and stood above the transport buttons. The bar is laid
    /// out for real in each state that changes its parts, at seven widths, in
    /// light and dark. The buttons stay at the same height whatever plays and
    /// at every width, so nothing jumps when a song starts or the window
    /// crosses the width where the bar stacks, and the bar stacks at the same
    /// width whatever it shows. Beside the sides, the scrubber's
    /// row keeps two fifths of the bar, as Spotify's does, so a window half a
    /// screen wide doesn't leave it at its narrowest.
    func testEveryPlayerBarControlSharesTheBarsCentreLine() async throws {
        let lyricsLabel = SpotiglassL10n.string("playback.controls.lyrics")
        let progressLabel = SpotiglassL10n.string("playback.scrubber.progress")
        let scrubberRow = try measuredScrubberRow()
        var buttonsLine: [String: CGFloat] = [:]
        for (state, makePlayback) in try await playerBarStates() {
            for (appearance, width) in [NSAppearance.Name.darkAqua, .aqua].flatMap({ name in
                [CGFloat(1_400), 1_100, 900, 760, 640, 580, 520].map { (name, $0) }
            }) {
                try withPlayerBar(state: state, playback: makePlayback(), width: width, appearance: appearance) { elements, window in
                    let controls = playerBarControls(in: elements)
                    func midY(_ element: RealizedAccessibilityElement) -> CGFloat {
                        (element.position?.y ?? 0) + element.size.height / 2
                    }
                    func midX(_ element: RealizedAccessibilityElement) -> CGFloat {
                        (element.position?.x ?? 0) + element.size.width / 2
                    }
                    func minX(_ element: RealizedAccessibilityElement) -> CGFloat { element.position?.x ?? 0 }
                    func maxX(_ element: RealizedAccessibilityElement) -> CGFloat { minX(element) + element.size.width }
                    func name(_ element: RealizedAccessibilityElement) -> String {
                        "\(element.role) \(element.axDescription.isEmpty ? element.title : element.axDescription)"
                    }
                    let label = "\(state), \(appearance.rawValue) at \(Int(width)): \(controls.map { "\(name($0)) x \(minX($0))-\(maxX($0)) y \(midY($0))" })"
                    let previous = try XCTUnwrap(
                        controls.first { $0.axDescription == SpotiglassL10n.string("playback.controls.previous") }, label
                    )
                    let scrubber = try XCTUnwrap(controls.first { $0.axDescription == progressLabel }, label)
                    XCTAssertGreaterThan(midY(scrubber), midY(previous) + 10, "the scrubber sits under the controls, \(label)")
                    // The scrubber's row: the bar and the times either side of it.
                    let scrubberRowMinX = minX(scrubber) - scrubberRow.overhead / 2
                    let scrubberRowMaxX = maxX(scrubber) + scrubberRow.overhead / 2
                    // The buttons' row is as tall as a button, the scrubber's row
                    // is centred on the scrubber.
                    let buttonsTop = midY(previous) - SpotiglassDesign.Layout.iconButtonSize / 2
                    let barMiddle = (buttonsTop + midY(scrubber) + scrubberRow.height / 2) / 2

                    // The transport cluster: Lyrics' slot, the three buttons and
                    // Repeat, symmetric around play/pause.
                    let centre = window.frame.minX + width / 2
                    let clusterHalfWidth = 2 * (centre - midX(previous)) + SpotiglassDesign.Layout.iconButtonSize / 2 + 1.5
                    func isSide(_ control: RealizedAccessibilityElement) -> Bool { abs(midX(control) - centre) > clusterHalfWidth }
                    let sideControls = controls.filter { $0.axDescription != progressLabel && isSide($0) }
                    for control in controls where control.axDescription != progressLabel && !isSide(control) {
                        XCTAssertEqual(midY(control), midY(previous), accuracy: 0.5, "\(name(control)) is off the buttons' row, \(label)")
                    }
                    // The sides sit on the bar's middle once the scrubber's row
                    // fits between them, which it does from 640 pt up.
                    let isStacked = sideControls.contains { maxX($0) > scrubberRowMinX - 0.5 && minX($0) < scrubberRowMaxX + 0.5 }
                    XCTAssertEqual(isStacked, width < 640, "the bar \(isStacked ? "stacks" : "doesn't stack"), \(label)")
                    let sidesLine = isStacked ? midY(previous) : barMiddle
                    if !isStacked {
                        let barInnerWidth = width - 4 * SpotiglassDesign.spacingM
                        XCTAssertGreaterThanOrEqual(
                            scrubberRowMaxX - scrubberRowMinX,
                            min(barInnerWidth * PlaybackTransportLayoutPolicy.scrubberShareOfBar, PlaybackTransportLayoutPolicy.scrubberMaximumWidth) - 1,
                            "the scrubber's row is narrower than two fifths of the bar, \(label)"
                        )
                    }
                    for control in sideControls {
                        XCTAssertEqual(midY(control), sidesLine, accuracy: 0.5, "\(name(control)) is off the \(isStacked ? "buttons' row" : "bar's middle"), \(label)")
                    }
                    XCTAssertTrue(
                        controls.contains { $0.role == "AXMenuButton" || $0.role == "AXPopUpButton" } || !state.contains("play"),
                        "the device menu is missing, \(label)"
                    )
                    // Whatever plays and at every width, the buttons stay where
                    // they are.
                    let key = appearance.rawValue
                    // Accessibility frames count from the top of the main screen.
                    let windowTop = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
                    let line = midY(previous) - windowTop
                    if let first = buttonsLine[key] {
                        XCTAssertEqual(line, first, accuracy: 0.5, "the buttons moved, \(label)")
                    } else {
                        buttonsLine[key] = line
                    }
                    // The title and the line under it (the artists, the state or
                    // the error), as one block: its top and bottom sit the same
                    // distance from the sides' line, and stacked it stays above
                    // the scrubber's row. They are the texts left of the
                    // transport buttons; the artist names are links.
                    let summaryEnd = previous.position?.x ?? 0
                    let text = elements.filter { element in
                        guard let position = element.position, element.size.height > 0 else { return false }
                        let isText = element.role == "AXStaticText" || element.title.contains("M83") || element.axDescription.contains("M83")
                        return isText && element.value != window.title
                            && position.x + element.size.width <= summaryEnd + 0.5
                            && (!isStacked || position.y + element.size.height <= (scrubber.position?.y ?? 0))
                    }
                    let top = try XCTUnwrap(text.compactMap { $0.position?.y }.min(), "no title, \(label)")
                    let bottom = try XCTUnwrap(text.compactMap { element in element.position.map { $0.y + element.size.height } }.max())
                    XCTAssertGreaterThan(text.count, 1, "the title and the line under it were not both found, \(text), \(label)")
                    XCTAssertEqual((top + bottom) / 2, sidesLine, accuracy: 1, "the title block is off the sides' line, \(text), \(label)")
                    if !isStacked {
                        for element in text {
                            XCTAssertLessThanOrEqual(maxX(element), scrubberRowMinX + 0.5, "\(element.value) runs over the scrubber's row, \(label)")
                        }
                    }

                    // The other service's song in the bar opens its own lyrics (#486).
                    let showsLyrics = ["playing", "long title", "paused", "apple music", "other service"].contains(state)
                    XCTAssertEqual(
                        controls.contains { $0.axDescription == lyricsLabel }, showsLyrics,
                        showsLyrics ? "the Lyrics button is missing, \(label)" : "no track, no Lyrics button, \(label)"
                    )
                    if state == "apple music" {
                        XCTAssertFalse(controls.contains { $0.axDescription == SpotiglassL10n.string("playback.controls.volume") }, "Apple Music has no volume control, \(label)")
                    }
                }
            }
        }
    }

    func testPlaybackTransportLayoutAtWindowMinimumKeepsScrubberUsable() throws {
        for size in [CGSize(width: 520, height: 360), CGSize(width: 760, height: 500)] {
            let controller = ViewTestHost.host(
                PlaybackControlsView(
                    viewModel: makePlayingPlayback(),
                    isLyricsPresented: .constant(false),
                    openArtist: { _ in }
                )
                .frame(width: size.width, height: size.height),
                size: size
            )
            let window = try XCTUnwrap(controller.view.window)
            window.title = "AXTestLayout\(Int(size.width))"
            controller.view.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: size)
            window.makeKeyAndOrderFront(nil)
            AppKitTestSupport.pumpRunLoop(for: 0.25)

            let elements = try realizedAccessibilityTree(in: window)
            let scrubber = try XCTUnwrap(
                elements.first { $0.axDescription == "Playback progress" },
                "Missing realised scrubber at \(size): \(elements)"
            )
            XCTAssertGreaterThanOrEqual(
                scrubber.size.width,
                PlaybackTransportLayoutPolicy.scrubberMinimumWidth,
                "Scrubber collapsed at \(size)"
            )
            // The narrowest window has room for the compact volume button
            // only; at 760 pt the slider fits beside the device menu, clear of
            // the scrubber's row between the two sides (#538).
            let volumeRole = size.width < 600 ? "AXButton" : "AXSlider"
            XCTAssertTrue(
                elements.contains { $0.role == volumeRole && $0.axDescription == "Playback volume" },
                "Expected the volume as \(volumeRole) at \(size): \(elements)"
            )
        }
    }

    func testConnectDeviceMenuUsesNativePickerRowsAndSelectionState() throws {
        let playback = makePlayingPlayback()
        playback.connectDevices = [
            MusicPlaybackDevice(
                deviceID: "connect-1",
                isActive: true,
                isRestricted: false,
                name: "Living Room",
                type: "speaker"
            ),
            MusicPlaybackDevice(
                deviceID: "connect-2",
                isActive: false,
                isRestricted: true,
                name: "Office Mac",
                type: "computer"
            ),
        ]
        playback.macAudioOutputDevices = [
            MacAudioOutputDevice(id: 11, name: "Built-in Output"),
            MacAudioOutputDevice(id: 12, name: "Headphones"),
        ]
        playback.systemDefaultOutputDeviceID = 12

        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )
        let picker = try view.inspect().find(ViewType.Picker.self) {
            try $0.labelView().text().string() == "Connect devices"
        }
        XCTAssertEqual(try picker.selectedValue(String.self), "connect-1")
        XCTAssertEqual(picker.findAll(ViewType.Label.self).count, 2)
        XCTAssertNoThrow(try picker.find(text: "Living Room"))
        let macPicker = try view.inspect().find(ViewType.Picker.self) {
            try $0.labelView().text().string() == "Mac audio outputs"
        }
        XCTAssertEqual(try macPicker.selectedValue(AudioDeviceID.self), 12)
        XCTAssertEqual(macPicker.findAll(ViewType.Label.self).count, 2)
        XCTAssertNoThrow(try macPicker.find(text: "Headphones"))
    }

    func testDeviceMenuHidesConnectDevicesWhenTheProviderCannotTransfer() throws {
        let playback = PlaybackSessionViewModel(provider: ReadOnlyStatePlaybackProvider())
        playback.handle(.ready(deviceID: "local"))
        playback.handle(.stateChanged(PlaybackNowPlaying(
            name: "Midnight City",
            artists: ["M83"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 240_000,
            positionMilliseconds: 30_000,
            uri: "music:song:1"
        ), isPaused: false, nextTracks: []))
        playback.macAudioOutputDevices = [MacAudioOutputDevice(id: 11, name: "Built-in Output")]
        playback.systemDefaultOutputDeviceID = 11

        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )
        let macPicker = try view.inspect().find(ViewType.Picker.self) {
            try $0.labelView().text().string() == "Mac audio outputs"
        }
        XCTAssertEqual(try macPicker.selectedValue(AudioDeviceID.self), 11)
        // Search only the device menu: an exhaustive miss over the whole bar
        // walks into views ViewInspector cannot read.
        let menuContent = try macPicker.find(ViewType.Group.self, relation: .parent)
        let pickers = menuContent.findAll(ViewType.Picker.self)
        XCTAssertEqual(try pickers.map { try $0.labelView().text().string() }, ["Mac audio outputs"])
    }

    func testPlaybackControlsEnablesPlayPauseForRemotePlayback() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.deviceID = "local-device"
        playback.setConnectionState(.ready(deviceID: "local-device"))
        playback.setActivePlaybackDeviceID("remote-device")
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        let playButton = try view.inspect().find(viewWithAccessibilityLabel: SpotiglassL10n.string("playback.play"))
        XCTAssertFalse(playButton.isDisabled())
    }

    func testPlaybackControlsArtistLineRendersOpenArtistButtons() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = makePlayingPlayback()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Open artist M83"))
    }

    func testPlaybackControlsKeepLyricsAndArtistActionsSeparate() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = makePlayingPlayback(artists: ["M83", "The Weeknd"])
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Lyrics"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Open lyrics"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Open artist M83"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Open artist The Weeknd"))
    }

    func testPlaybackArtistLineScrollPolicyDetectsOverflowAndReducedMotion() {
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.maxScrollOffset(contentWidth: 200, viewportWidth: 240),
            0
        )
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.maxScrollOffset(contentWidth: 360, viewportWidth: 240),
            120
        )
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.clampedScrollOffset(-1, maxScrollOffset: 120),
            0
        )
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.clampedScrollOffset(240, maxScrollOffset: 120),
            120
        )
        XCTAssertTrue(
            PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                maxScrollOffset: 120,
                reduceMotion: false,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                maxScrollOffset: 120,
                reduceMotion: true,
                isUserInteracting: false
            )
        )
        XCTAssertFalse(
            PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                maxScrollOffset: 120,
                reduceMotion: false,
                isUserInteracting: true
            )
        )
        XCTAssertFalse(
            PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                maxScrollOffset: 0,
                reduceMotion: false,
                isUserInteracting: false
            )
        )
        XCTAssertNil(PlaybackArtistLineScrollPolicy.animation(duration: 2, reduceMotion: true))
        XCTAssertNotNil(PlaybackArtistLineScrollPolicy.animation(duration: 2, reduceMotion: false))
        XCTAssertNil(
            PlaybackArtistLineScrollPolicy.resetOffset(
                previousResetID: "track-1",
                resetID: "track-1"
            )
        )
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.resetOffset(previousResetID: "track-1", resetID: "track-2"),
            0
        )
        XCTAssertEqual(PlaybackArtistLineScrollPolicy.duration(for: 0), 0)
        XCTAssertEqual(
            PlaybackArtistLineScrollPolicy.duration(for: 1),
            SpotiglassDesign.nowPlayingArtistLineMinimumScrollDuration
        )
        XCTAssertGreaterThan(
            PlaybackArtistLineScrollPolicy.duration(for: 120),
            SpotiglassDesign.nowPlayingArtistLineMinimumScrollDuration
        )
    }

    func testTrackRowVisualStateSeparatesSelectionFromCurrentPlayback() {
        XCTAssertEqual(
            TrackRowVisualState.resolve(isSelected: false, isCurrent: false),
            .unselected
        )
        XCTAssertEqual(
            TrackRowVisualState.resolve(isSelected: true, isCurrent: false),
            .selected
        )
        XCTAssertEqual(
            TrackRowVisualState.resolve(isSelected: false, isCurrent: true),
            .current
        )
        XCTAssertEqual(
            TrackRowVisualState.resolve(isSelected: true, isCurrent: true),
            .selectedAndCurrent
        )
        XCTAssertFalse(TrackRowVisualState.current.showsSelectionIndicator)
        XCTAssertTrue(TrackRowVisualState.selected.showsSelectionIndicator)
        XCTAssertTrue(TrackRowVisualState.selectedAndCurrent.showsSelectionIndicator)
    }

    func testPlaybackControlsPausedShowsPausedBadge() throws {
        let playback = makePlayingPlayback(paused: true)
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Paused"))
    }

    func testQueuePanelEmptyStates() async throws {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        await playback.syncTransportFromSpotify()
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        ViewTestHost.assertFindLocalizedText("queue.title", in: view)
        ViewTestHost.assertFindText("Nothing playing", in: view)
        ViewTestHost.assertFindText(
            "No upcoming tracks. Start a playlist or add tracks to the queue.",
            in: view
        )
    }

    func testQueuePanelOmitsPlayAndCopyActionsForURIlessRows() throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.nowPlayingItem = QueueItem(
            name: "Display only",
            subtitle: "Unavailable",
            albumArtURL: nil,
            durationMilliseconds: 0,
            uri: " \n\t"
        )

        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))

        XCTAssertThrowsError(try view.inspect().find(button: "Play Now"))
        XCTAssertThrowsError(try view.inspect().find(button: "Copy URI"))
    }

    func testQueuePanelPopulatedNowPlayingAndUpNext() async throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )

        playback.handle(.ready(deviceID: "device-1"))
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:current"
        )
        let next = PlaybackNowPlaying(
            name: "Next",
            artists: ["Next Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:next"
        )
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: [next]))

        let trackCurrent = MusicTrack(
            id: "current",
            name: "Current",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:current"
        )
        let trackNext = MusicTrack(
            id: "next",
            name: "Next",
            artists: ["Next Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:next"
        )
        api.queueResponse = MusicPlaybackQueue(queue: [.track(trackCurrent), .track(trackNext)])

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        XCTAssertNoThrow(try view.inspect().find(text: "Now playing"))
        XCTAssertNoThrow(try view.inspect().find(text: "Up next"))
        XCTAssertNoThrow(try view.inspect().find(text: "Next"))
    }

    func testQueuePanelShowsPlaybackUnavailableError() async throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )

        await queue.addToQueue(uri: "spotify:track:missing-device")

        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback unavailable"))
    }

    func testQueuePanelRepeatOneSubtitle() async throws {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .track),
            activeDevice: nil,
            isPlaying: false
        )]
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        await playback.syncTransportFromSpotify()
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        // Assert through the catalog rather than a hard-coded English literal.
        // This test pinned the old copy verbatim, so removing an em dash from the
        // string broke it for a reason that had nothing to do with the behavior
        // under test.
        ViewTestHost.assertFindLocalizedText("queue.subtitle.repeatOne", in: view)
    }

    private struct RealizedAccessibilityElement: CustomStringConvertible {
        let role: String
        let axDescription: String
        let title: String
        let value: String
        let position: CGPoint?
        let size: CGSize
        let depth: Int

        var description: String {
            let positionDescription = position.map { String(describing: $0) } ?? "<unavailable>"
            return "role=\(role.debugDescription) description=\(axDescription.debugDescription) title=\(title.debugDescription) value=\(value.debugDescription) position=\(positionDescription) size=\(size)"
        }

        var isInteractiveTransportControl: Bool {
            switch role {
            case "AXButton", "AXMenuButton", "AXPopUpButton", "AXSlider", "AXUnknown":
                true
            default:
                false
            }
        }

        var hasMeaningfulAccessibilityLabel: Bool {
            [axDescription, title].contains { candidate in
                let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                return !label.isEmpty && label.caseInsensitiveCompare("button") != .orderedSame
            }
        }
    }

    private func realizedAccessibilityTreeDescription(
        _ elements: [RealizedAccessibilityElement]
    ) -> String {
        guard !elements.isEmpty else { return "<empty>" }
        return elements.map { element in
            String(repeating: "  ", count: element.depth) + element.description
        }.joined(separator: "\n")
    }

    private func realizedAccessibilitySubtree(
        containingAccessibilityDescription description: String,
        in elements: [RealizedAccessibilityElement]
    ) -> [RealizedAccessibilityElement]? {
        guard let matchIndex = elements.firstIndex(where: { $0.axDescription == description }),
              let rootIndex = elements[..<matchIndex].lastIndex(where: { $0.depth == 1 })
        else { return nil }

        let rootDepth = elements[rootIndex].depth
        let endIndex = elements[(rootIndex + 1)...].firstIndex { $0.depth <= rootDepth } ?? elements.endIndex
        return Array(elements[rootIndex..<endIndex])
    }

    private func realizedAccessibilityTree(in window: NSWindow) throws -> [RealizedAccessibilityElement] {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = try axChildren(of: application, attribute: kAXWindowsAttribute)
        let windowElement = try XCTUnwrap(
            windows.first { axString($0, attribute: kAXTitleAttribute) == window.title },
            "Could not find AX window \(window.title); got \(windows.map { axString($0, attribute: kAXTitleAttribute) })"
        )
        return axDescendants(of: windowElement)
    }

    private func realizedAccessibilityTreeIfAvailable(in window: NSWindow) -> [RealizedAccessibilityElement]? {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let windows = try? axChildren(of: application, attribute: kAXWindowsAttribute),
              let windowElement = windows.first(where: { axString($0, attribute: kAXTitleAttribute) == window.title }),
              let children = try? axChildren(of: windowElement, attribute: kAXChildrenAttribute),
              !children.isEmpty
        else {
            return nil
        }
        return axDescendants(of: windowElement)
    }

    private func axDescendants(
        of element: AXUIElement,
        depth: Int = 0
    ) -> [RealizedAccessibilityElement] {
        let snapshot = RealizedAccessibilityElement(
            role: axString(element, attribute: kAXRoleAttribute),
            axDescription: axString(element, attribute: kAXDescriptionAttribute),
            title: axString(element, attribute: kAXTitleAttribute),
            value: axValueString(element),
            position: axPosition(element),
            size: axSize(element),
            depth: depth
        )
        let children = (try? axChildren(of: element, attribute: kAXChildrenAttribute)) ?? []
        return [snapshot] + children.flatMap { axDescendants(of: $0, depth: depth + 1) }
    }

    /// Descriptions in the order VoiceOver moves through them: each element's
    /// children in navigation order, which sort priorities change, where the
    /// plain child list keeps the declaration order.
    private func voiceOverOrder(in window: NSWindow) throws -> [String] {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = try axChildren(of: application, attribute: kAXWindowsAttribute)
        let windowElement = try XCTUnwrap(windows.first { axString($0, attribute: kAXTitleAttribute) == window.title })
        func walk(_ element: AXUIElement) -> [String] {
            let children = (try? axChildren(of: element, attribute: "AXChildrenInNavigationOrder"))
                ?? (try? axChildren(of: element, attribute: kAXChildrenAttribute)) ?? []
            let own = axString(element, attribute: kAXDescriptionAttribute)
            return (own.isEmpty ? [] : [own]) + children.flatMap(walk)
        }
        return walk(windowElement)
    }

    private func axChildren(of element: AXUIElement, attribute: String) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            throw NSError(domain: "Accessibility", code: Int(result.rawValue))
        }
        return (value as? [AXUIElement]) ?? []
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func axPosition(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &position) else { return nil }
        return position
    }

    private func axSize(_ element: AXUIElement) -> CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value
        else { return .zero }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return .zero }
        return size
    }

    private func axValueString(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return ""
        }
        return value.map(String.init(describing:)) ?? ""
    }

    private func allNSButtons(in view: NSView) -> [NSButton] {
        let own = view as? NSButton
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { allNSButtons(in: $0) }
    }

    private func makePlayingPlayback(
        paused: Bool = false,
        artists: [String] = ["M83"]
    ) -> PlaybackSessionViewModel {
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(Self.midnightCity(artists: artists), isPaused: paused, nextTracks: []))
        return playback
    }

    private static func midnightCity(
        name: String = "Midnight City",
        artists: [String] = ["M83"],
        positionMilliseconds: Int = 30_000
    ) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: name,
            artists: artists,
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 240_000,
            positionMilliseconds: positionMilliseconds,
            uri: "spotify:track:midnight"
        )
    }
}

/// SwiftUI hands mouse events to gestures only in the key window. A test run
/// cannot always make its process the active app, so this window reports
/// itself key without taking focus from whatever is in front.
private final class KeyTestPanel: OffscreenTestPanel {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// Seeks the mock API was asked for. Playback calls run on background tasks.
private final class SentSeeks: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] { lock.withLock { stored } }

    func append(_ milliseconds: Int) {
        lock.withLock { stored.append(milliseconds) }
    }
}
