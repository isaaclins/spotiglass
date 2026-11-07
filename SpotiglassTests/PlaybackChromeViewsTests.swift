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
    /// survives a player update and the window passing through the stacked
    /// arrangement and back, and the release seeks once, at the pointer.
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

    /// The arrangement must place every part where main's `ViewThatFits` over
    /// three stacks placed it, so the bar looks the same at every width the
    /// window allows. Both are built from the same stand-in parts here (the
    /// real parts' sizes) and compared frame by frame. The first version gave
    /// Spotify's slider its ideal width in tight rows, where the old row let it
    /// shrink to its floor.
    ///
    /// One deliberate difference: where main ran the trailing controls into the
    /// gap before the scrubber (Spotify, rows about 950 to 1080 pt wide, and
    /// wherever the 170 pt Reconnect or Retry button shows), the arrangement
    /// keeps the gap and the summary and scrubber give up the room. Every part
    /// also has to lie inside the size the arrangement reports, or it spills
    /// into the bar's padding.
    func testTransportArrangementPlacesEveryPartWhereTheOldStacksDid() throws {
        let spacing = SpotiglassDesign.spacingM
        for (withVolume, recovery) in [(true, false), (false, false), (true, true), (false, true)] {
            var mismatches: [String] = []
            var overlapping = 0
            let label = "volume: \(withVolume), recovery button: \(recovery)"
            // From the narrowest transport the 520 pt window leaves.
            for width in stride(from: CGFloat(456), through: 1_400, by: 8) {
                let old = try partFrames(
                    of: OldTransportArrangement(withVolume: withVolume, recovery: recovery), width: width
                )
                let new = try partFrames(
                    of: NewTransportArrangement(withVolume: withVolume, recovery: recovery), width: width
                )
                XCTAssertEqual(Set(old.keys), Set(new.keys), "parts at \(width)")
                if let whole = new[PartFrameKey.whole] {
                    for (part, frame) in new where part != PartFrameKey.whole {
                        XCTAssertTrue(
                            frame.minX >= whole.minX - 0.5 && frame.maxX <= whole.maxX + 0.5,
                            "\(part) \(frame) spills out of the bar \(whole) at \(width), \(label)"
                        )
                    }
                }
                // One row when the scrubber and the controls share a centre line.
                func inOneRow(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.midY - b.midY) < 1 }
                if let scrubber = new["scrubber"], let controls = new["controls"], inOneRow(scrubber, controls) {
                    XCTAssertGreaterThanOrEqual(
                        controls.minX - scrubber.maxX, spacing - 0.5, "the controls run into the scrubber at \(width)"
                    )
                }
                if let scrubber = old["scrubber"], let controls = old["controls"], inOneRow(scrubber, controls),
                   controls.minX - scrubber.maxX < spacing - 0.5 {
                    overlapping += 1
                    continue
                }
                for (part, oldFrame) in old.sorted(by: { $0.key < $1.key }) {
                    guard let newFrame = new[part] else { continue }
                    let deltas = [oldFrame.minX - newFrame.minX, oldFrame.minY - newFrame.minY,
                                  oldFrame.width - newFrame.width, oldFrame.height - newFrame.height]
                    if deltas.contains(where: { abs($0) > 0.5 }) {
                        mismatches.append("\(Int(width)) \(part): main \(oldFrame), now \(newFrame)")
                    }
                }
            }
            // The narrowest the bar can get, which the window's minimum size
            // comes from: the same as main, so the parts always fit in it.
            let oldMinimum = try XCTUnwrap(
                partFrames(of: OldTransportArrangement(withVolume: withVolume, recovery: recovery), width: 0)[PartFrameKey.whole]
            )
            let newMinimum = try partFrames(
                of: NewTransportArrangement(withVolume: withVolume, recovery: recovery), width: 0
            )
            XCTAssertEqual(newMinimum[PartFrameKey.whole]?.width ?? 0, oldMinimum.width, accuracy: 0.5, "minimum, \(label)")
            if let whole = newMinimum[PartFrameKey.whole] {
                for (part, frame) in newMinimum where part != PartFrameKey.whole {
                    XCTAssertLessThanOrEqual(frame.maxX, whole.maxX + 0.5, "\(part) spills out at the minimum, \(label)")
                }
            }
            XCTAssertEqual(mismatches, [], label)
            if !recovery {
                // Without the wide button the overlap is Spotify's slider row
                // only, and only a narrow band of it.
                XCTAssertLessThanOrEqual(overlapping, withVolume ? 20 : 0, label)
            }
        }
    }

    /// Each part's frame in the arrangement's own coordinates, laid out at `width`.
    private func partFrames<V: View>(of view: V, width: CGFloat) throws -> [String: CGRect] {
        let store = PartFrameStore()
        let host = NSHostingView(
            rootView: view
                .reportsFrame(as: PartFrameKey.whole)
                .frame(width: width)
                .coordinateSpace(.named(PartFrameKey.space))
                .onPreferenceChange(PartFrameKey.self) { store.frames = $0 }
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.01)
        return store.frames
    }

    func testPlaybackTransportLayoutAtWindowMinimumKeepsScrubberUsable() throws {
        for size in [CGSize(width: 520, height: 360), CGSize(width: 700, height: 500)] {
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
            XCTAssertTrue(
                elements.contains { $0.role == "AXButton" && $0.axDescription == "Playback volume" },
                "Expected compact volume control at \(size)"
            )
        }
    }

    /// The floors a row reserves: the summary, the scrubber's seeking surface
    /// and the trailing controls, with the two gaps between them.
    private func rowMinimumWidth(compactVolume: Bool) -> CGFloat {
        PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth
            + PlaybackTransportLayoutPolicy.scrubberMinimumWidth
            + PlaybackTransportLayoutPolicy.transportActionsMinimumWidth(useCompactVolume: compactVolume)
            + 2 * SpotiglassDesign.spacingM
    }

    func testPlaybackTransportRowFloorsFitEveryWidthThatPicksARow() {
        for width in stride(from: CGFloat(320), through: CGFloat(1600), by: 10) {
            guard case let .row(compactVolume) = PlaybackTransportArrangementLayout.arrangement(
                forWidth: width,
                idealRowWidth: { _ in 0 }
            ) else { continue }
            XCTAssertLessThanOrEqual(
                rowMinimumWidth(compactVolume: compactVolume),
                width,
                "Transport row floors no longer fit at width \(width)"
            )
        }
    }

    /// The candidate `PlaybackTransportArrangementLayout` picks for a width
    /// when every ideal row fits, so only the candidates' minimum widths decide.
    private func transportLayoutCandidate(
        for measuredWidth: CGFloat
    ) -> PlaybackTransportLayoutPolicy.TransportLayoutCandidate {
        let candidates = PlaybackTransportLayoutPolicy.transportLayoutCandidates()
        guard measuredWidth.isFinite else { return candidates.last! }
        switch PlaybackTransportArrangementLayout.arrangement(forWidth: measuredWidth, idealRowWidth: { _ in 0 }) {
        case .row(let compactVolume):
            return candidates.first { $0.minimumWidth > 0 && $0.useCompactVolume == compactVolume }!
        case .stacked:
            return candidates.last!
        }
    }

    /// A row is only chosen when its ideal width fits too, as `ViewThatFits`
    /// chose before: a long ideal row falls back to the compact row, then to
    /// the stacked arrangement, and an ideal-size query gets the full row.
    func testTransportArrangementNeedsTheIdealRowToFit() {
        let idealRow: (Bool) -> CGFloat = { compactVolume in compactVolume ? 808 : 904 }
        func arrangement(_ width: CGFloat?) -> PlaybackTransportArrangementLayout.Arrangement {
            PlaybackTransportArrangementLayout.arrangement(forWidth: width, idealRowWidth: idealRow)
        }
        XCTAssertEqual(arrangement(1_240), .row(compactVolume: false))
        XCTAssertEqual(arrangement(904), .row(compactVolume: false))
        XCTAssertEqual(arrangement(903), .row(compactVolume: true))
        XCTAssertEqual(arrangement(808), .row(compactVolume: true))
        XCTAssertEqual(arrangement(807), .stacked)
        XCTAssertEqual(arrangement(0), .stacked)
        XCTAssertEqual(arrangement(nil), .row(compactVolume: false))
    }

    func testPlaybackTransportLayoutCandidatesReachFixedPointsAcrossDenseWidthSweep() {
        let fullCandidate = PlaybackTransportLayoutPolicy.TransportLayoutCandidate(
            useCompactVolume: false,
            minimumWidth: PlaybackTransportLayoutPolicy.compactVolumeBreakpoint
        )
        let compactCandidate = PlaybackTransportLayoutPolicy.TransportLayoutCandidate(
            useCompactVolume: true,
            minimumWidth: PlaybackTransportLayoutPolicy.stackedScrubberBreakpoint
        )

        XCTAssertEqual(
            transportLayoutCandidate(
                for: PlaybackTransportLayoutPolicy.compactVolumeBreakpoint - 1
            ),
            compactCandidate
        )
        XCTAssertEqual(
            transportLayoutCandidate(
                for: PlaybackTransportLayoutPolicy.compactVolumeBreakpoint + 1
            ),
            fullCandidate
        )

        for width in stride(from: CGFloat(320), through: CGFloat(1600), by: 1) {
            let firstCandidate = transportLayoutCandidate(for: width)
            // Model the selected candidate's minimum feeding back through
            // layout: the selected candidate must remain selected.
            let measuredAgain = max(width, firstCandidate.minimumWidth)
            let secondCandidate = transportLayoutCandidate(for: measuredAgain)

            XCTAssertEqual(
                secondCandidate,
                firstCandidate,
                "Transport arrangement oscillated at measured width \(width)"
            )
            // The stacked arrangement is the always-fits fallback, and is the
            // only candidate declaring a zero minimum. Every other candidate is
            // horizontal and must genuinely fit the width it was selected for.
            if firstCandidate.minimumWidth > 0 {
                XCTAssertLessThanOrEqual(
                    rowMinimumWidth(compactVolume: firstCandidate.useCompactVolume),
                    width,
                    "Horizontal candidate does not fit at measured width \(width)"
                )
            }
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
        artists: [String] = ["M83"],
        positionMilliseconds: Int = 30_000
    ) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Midnight City",
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
private final class KeyTestPanel: NSPanel {
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

// MARK: - Main's transport arrangement, for comparison

private final class PartFrameStore {
    var frames: [String: CGRect] = [:]
}

private struct PartFrameKey: PreferenceKey {
    static let space = "transport"
    static let whole = "the whole bar"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func reportsFrame(as part: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(
                key: PartFrameKey.self,
                value: [part: geometry.frame(in: .named(PartFrameKey.space))]
            )
        })
    }
}

/// Stand-ins with the real parts' sizing: a summary that truncates, the
/// scrubber group's labels and flexible track, the fixed transport buttons, a
/// device menu that can shrink, and the real volume control's icon and slider.
private enum TransportStandIns {
    static var summary: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Color.gray.frame(width: 44, height: 44)
            Text("Midnight City, a title long enough to truncate").font(.headline).lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    static var scrubber: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text("0:00").font(.caption.monospacedDigit()).frame(minWidth: 36, alignment: .trailing)
            Color.clear.frame(height: 18).frame(minWidth: 180, maxWidth: .infinity)
            Text("−0:00").font(.caption.monospacedDigit()).frame(minWidth: 40, alignment: .leading)
        }
    }

    /// The transport buttons, with the 170 pt Reconnect or Retry button in
    /// front of them while the player needs it.
    static func controls(recovery: Bool) -> some View {
        Color.red.frame(width: recovery ? 142 + 170 + SpotiglassDesign.spacingS : 142, height: 28)
    }
    /// The device menu's bezel lets it shrink from 52 to 38 pt, measured in the app.
    static var device: some View { Color.blue.frame(minWidth: 38, idealWidth: 52, maxWidth: 52).frame(height: 28) }

    static var volume: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: "speaker.wave.2").font(.caption)
            Slider(value: .constant(0.5), in: 0 ... 1)
                .controlSize(.small)
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.minimum,
                    idealWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.ideal,
                    maxWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.maximum
                )
        }
    }

    static var compactVolume: some View { Color.green.frame(width: 28, height: 28) }
}

/// The arrangement as it was on main: `ViewThatFits` over two rows and a stack.
private struct OldTransportArrangement: View {
    var withVolume: Bool
    var recovery: Bool

    var body: some View {
        let candidates = PlaybackTransportLayoutPolicy.transportLayoutCandidates()
        ViewThatFits(in: .horizontal) {
            row(compactVolume: candidates[0].useCompactVolume).frame(minWidth: candidates[0].minimumWidth)
            row(compactVolume: candidates[1].useCompactVolume).frame(minWidth: candidates[1].minimumWidth)
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                actions(compactVolume: true, includeSummary: true)
                TransportStandIns.scrubber
                    .frame(minWidth: PlaybackTransportLayoutPolicy.scrubberMinimumWidth, maxWidth: .infinity)
                    .reportsFrame(as: "scrubber")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func row(compactVolume: Bool) -> some View {
        HStack(spacing: SpotiglassDesign.spacingM) {
            TransportStandIns.summary
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
                    idealWidth: 280,
                    maxWidth: 320,
                    alignment: .leading
                )
                .clipped()
                .reportsFrame(as: "summary")
            TransportStandIns.scrubber
                .frame(minWidth: PlaybackTransportLayoutPolicy.scrubberMinimumWidth, maxWidth: .infinity)
                .reportsFrame(as: "scrubber")
            actions(compactVolume: compactVolume, includeSummary: false)
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.transportActionsMinimumWidth(useCompactVolume: compactVolume),
                    alignment: .trailing
                )
        }
    }

    private func actions(compactVolume: Bool, includeSummary: Bool) -> some View {
        HStack(spacing: SpotiglassDesign.spacingM) {
            if includeSummary {
                TransportStandIns.summary
                    .frame(
                        minWidth: PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .clipped()
                    .reportsFrame(as: "summary")
            }
            TransportStandIns.controls(recovery: recovery).reportsFrame(as: "controls")
            TransportStandIns.device.reportsFrame(as: "device")
            if withVolume {
                if compactVolume {
                    TransportStandIns.compactVolume.reportsFrame(as: "volume")
                } else {
                    TransportStandIns.volume.reportsFrame(as: "volume")
                }
            }
        }
    }
}

/// The same parts in `PlaybackTransportArrangementLayout`, as `PlaybackControlsView` builds it.
private struct NewTransportArrangement: View {
    var withVolume: Bool
    var recovery: Bool

    private typealias Part = PlaybackTransportArrangementLayout.PartKey

    var body: some View {
        PlaybackTransportArrangementLayout(
            spacing: SpotiglassDesign.spacingM,
            rowSpacing: SpotiglassDesign.spacingS
        ) {
            TransportStandIns.summary
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .clipped()
                .reportsFrame(as: "summary")
                .layoutValue(key: Part.self, value: .summary)
            TransportStandIns.scrubber
                .frame(minWidth: PlaybackTransportLayoutPolicy.scrubberMinimumWidth, maxWidth: .infinity)
                .reportsFrame(as: "scrubber")
                .layoutValue(key: Part.self, value: .scrubber)
            TransportStandIns.controls(recovery: recovery)
                .reportsFrame(as: "controls")
                .layoutValue(key: Part.self, value: .controls)
            TransportStandIns.device
                .reportsFrame(as: "device")
                .layoutValue(key: Part.self, value: .device)
            if withVolume {
                PlaybackTransportVolumeSlot {
                    TransportStandIns.volume.reportsFrame(as: "volume")
                } compact: {
                    TransportStandIns.compactVolume.reportsFrame(as: "volume")
                }
                .layoutValue(key: Part.self, value: .volume)
            }
        }
    }
}
