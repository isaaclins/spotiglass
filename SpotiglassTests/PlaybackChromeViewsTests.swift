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
            displayFraction: 0.42,
            durationMilliseconds: 180_000,
            onSeek: { _ in },
            onDragUpdate: { _ in }
        )
        .frame(width: 280, height: 24)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 48))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityLabel: "Playback progress"))
    }

    func testPlaybackProgressScrubberGroupStaticLabels() throws {
        let view = PlaybackProgressScrubberGroup(
            progressAnchor: PlaybackProgressAnchor(
                positionMilliseconds: 90_000,
                anchorDate: Date(),
                durationMilliseconds: 180_000,
                isAdvancing: false
            ),
            durationMilliseconds: 180_000,
            isEnabled: true,
            onSeek: { _ in },
            dragFraction: .constant(nil)
        )
        .frame(width: 360)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 48))
        XCTAssertNoThrow(try view.inspect().find(text: "1:30"))
        XCTAssertNoThrow(try view.inspect().find(text: "−1:30"))
    }

    func testPlaybackControlsDisconnectedState() throws {
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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

    func testPlaybackLyricsTransportButtonsRespondToMouseClick() throws {
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
        let window = try XCTUnwrap(controller.view.window)
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

        window.makeKeyAndOrderFront(nil)
        AppKitTestSupport.activateAppIfNeeded()
        AppKitTestSupport.pumpRunLoop()
        try sendMouseClick(on: lyricsButton, in: window)
        XCTAssertTrue(isPresented, "A click on the Lyrics transport button did not present lyrics")

        isPresented = false
        try sendMouseClick(on: artworkLyricsButton, in: window)
        XCTAssertTrue(isPresented, "A click on the artwork lyrics button did not present lyrics")
    }

    private func sendMouseClick(on button: NSButton, in window: NSWindow) throws {
        let location = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        for (eventNumber, eventType) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: eventType,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: eventNumber,
                    clickCount: 1,
                    pressure: 1
                )
            )
            NSApp.sendEvent(event)
        }
        AppKitTestSupport.pumpRunLoop()
    }

    func testPlaybackControlsConnectingState() throws {
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
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
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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

    func testPlaybackTransportLayoutAtWindowMinimumKeepsScrubberUsable() throws {
        XCTAssertEqual(PlaybackTransportLayoutPolicy.scrubberWidth(in: 520), 180)
        XCTAssertEqual(PlaybackTransportLayoutPolicy.scrubberWidth(in: 700), 180)
        XCTAssertTrue(PlaybackTransportLayoutPolicy.usesCompactVolume(for: 520))
        XCTAssertTrue(PlaybackTransportLayoutPolicy.usesCompactVolume(for: 700))
        XCTAssertFalse(PlaybackTransportLayoutPolicy.usesCompactVolume(for: 900))

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

    func testPlaybackTransportMinimumWidthsReserveSummaryAndFitContainer() {
        for width in stride(from: CGFloat(700), through: CGFloat(1600), by: 10) {
            let minimumWidths = PlaybackTransportLayoutPolicy.transportChildMinimumWidths(in: width)

            XCTAssertGreaterThan(
                minimumWidths.summary,
                0,
                "Now-playing summary lost its floor at transport width \(width)"
            )
            XCTAssertLessThanOrEqual(
                minimumWidths.summary
                    + minimumWidths.scrubber
                    + minimumWidths.actions
                    + (2 * SpotiglassDesign.spacingM),
                width,
                "Transport child minimums no longer fit at width \(width)"
            )
        }
    }

    /// Mirrors the selection `ViewThatFits` performs over
    /// `transportLayoutCandidates()`: the first candidate whose minimum width
    /// the proposal satisfies, falling back to the stacked arrangement. Lives
    /// in the test target because production selects structurally, by handing
    /// each candidate's minimum to `ViewThatFits` as a frame, rather than by
    /// computing a candidate from a measured width.
    private func transportLayoutCandidate(
        for measuredWidth: CGFloat
    ) -> PlaybackTransportLayoutPolicy.TransportLayoutCandidate {
        let candidates = PlaybackTransportLayoutPolicy.transportLayoutCandidates()
        guard measuredWidth.isFinite else { return candidates.last! }
        return candidates.first { measuredWidth >= $0.minimumWidth } ?? candidates.last!
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
            let firstMinimums = PlaybackTransportLayoutPolicy.transportChildMinimumWidths(
                in: width,
                useCompactVolume: firstCandidate.useCompactVolume
            )
            // Model ViewThatFits feeding the selected candidate's frame back
            // through layout: the selected candidate must remain selected and
            // its complete child-minimum computation must remain unchanged.
            let measuredAgain = max(width, firstCandidate.minimumWidth)
            let secondCandidate = transportLayoutCandidate(for: measuredAgain)
            let secondMinimums = PlaybackTransportLayoutPolicy.transportChildMinimumWidths(
                in: measuredAgain,
                useCompactVolume: secondCandidate.useCompactVolume
            )

            XCTAssertEqual(
                secondCandidate,
                firstCandidate,
                "Transport arrangement oscillated at measured width \(width)"
            )
            XCTAssertEqual(
                secondMinimums,
                firstMinimums,
                "Transport child minimums did not converge at measured width \(width)"
            )
            // The stacked arrangement is the always-fits fallback, and is the
            // only candidate declaring a zero minimum. Every other candidate is
            // horizontal and must genuinely fit the width it was selected for.
            if firstCandidate.minimumWidth > 0 {
                XCTAssertLessThanOrEqual(
                    firstMinimums.summary
                        + firstMinimums.scrubber
                        + firstMinimums.actions
                        + (2 * SpotiglassDesign.spacingM),
                    width,
                    "Horizontal candidate does not fit at measured width \(width)"
                )
            }
        }
    }

    func testConnectDeviceMenuUsesNativePickerRowsAndSelectionState() throws {
        let playback = makePlayingPlayback()
        playback.connectDevices = [
            SpotifyConnectDevice(
                deviceID: "connect-1",
                isActive: true,
                isRestricted: false,
                name: "Living Room",
                type: "speaker"
            ),
            SpotifyConnectDevice(
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
        let picker = try view.inspect().find(ViewType.Picker.self)
        XCTAssertEqual(try picker.labelView().text().string(), "Connect devices")
        XCTAssertEqual(try picker.selectedValue(String.self), "connect-1")
        XCTAssertEqual(picker.findAll(ViewType.Label.self).count, 2)
        XCTAssertNoThrow(try picker.find(text: "Living Room"))
        let macPicker = try view.inspect().find(ViewType.Picker.self, skipFound: 1)
        XCTAssertEqual(try macPicker.labelView().text().string(), "Mac audio outputs")
        XCTAssertEqual(try macPicker.selectedValue(AudioDeviceID.self), 12)
        XCTAssertEqual(macPicker.findAll(ViewType.Label.self).count, 2)
        XCTAssertNoThrow(try macPicker.find(text: "Headphones"))
    }

    func testPlaybackControlsEnablesPlayPauseForRemotePlayback() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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
        api.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        await playback.syncTransportFromSpotify()
        let queue = QueueViewModel(
            playbackAPI: api,
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
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
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
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
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

        let trackCurrent = SpotifyTrack(
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
        let trackNext = SpotifyTrack(
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
        api.queueResponse = SpotifyQueueResponse(queue: [.track(trackCurrent), .track(trackNext)])

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
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
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
        api.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .track),
            activeDevice: nil,
            isPlaying: false
        )]
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        await playback.syncTransportFromSpotify()
        let queue = QueueViewModel(
            playbackAPI: api,
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
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.handle(.ready(deviceID: "device-1"))
        let nowPlaying = PlaybackNowPlaying(
            name: "Midnight City",
            artists: artists,
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 240_000,
            positionMilliseconds: 30_000,
            uri: "spotify:track:midnight"
        )
        playback.handle(.stateChanged(nowPlaying, isPaused: paused, nextTracks: []))
        return playback
    }
}
