import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackConnectDevicesAndTransferTests: XCTestCase {
    func testNewReadyEventReplacesPriorAutoResumeTask() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "stale-spotiglass",
                isActive: true,
                isRestricted: false,
                name: SpotifyPlaybackHost.deviceName,
                type: "computer"
            )
        ]
        let refreshStarted = AsyncSignal()
        let releaseRefresh = AsyncSignal()
        let transferStarted = AsyncSignal()
        playbackAPI.onFetchAvailableDevices = {
            refreshStarted.signal()
            await releaseRefresh.wait()
        }
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.autoResumeOnNextReady = true
        viewModel.handle(.ready(deviceID: "device-1"))

        let didStart = await refreshStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        viewModel.handle(.ready(deviceID: "device-2"))
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "device-2"))

        releaseRefresh.signal()
        let didTransfer = await transferStarted.wait(timeout: .seconds(1))

        XCTAssertTrue(didTransfer)
        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:device-2:false"]
        )
        XCTAssertFalse(playbackAPI.actions.contains("transfer:device-1:false"))
        XCTAssertEqual(viewModel.connectionState, .transferring(deviceID: "device-2"))
    }

    func testDisconnectDuringAutoResumeDeviceRefreshSuppressesLateRefreshAndTransfer() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        let refreshStarted = AsyncSignal()
        let releaseRefresh = AsyncSignal()
        let transferStarted = AsyncSignal()
        playbackAPI.onFetchAvailableDevices = {
            refreshStarted.signal()
            await releaseRefresh.wait()
        }
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.autoResumeOnNextReady = true
        viewModel.handle(.ready(deviceID: "new-spotiglass"))

        let didStart = await refreshStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        await viewModel.disconnect()
        releaseRefresh.signal()
        let didTransfer = await transferStarted.wait(timeout: .milliseconds(100))

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(didTransfer)
        XCTAssertNil(viewModel.deviceID)
        XCTAssertTrue(viewModel.connectDevices.isEmpty)
        XCTAssertFalse(viewModel.isRefreshingConnectDevices)
        XCTAssertFalse(playbackAPI.actions.contains { $0.hasPrefix("transfer:") })
    }

    func testReadyAutoResumeUsesInitialSnapshotWithoutDuplicatePlayerRead() async {
        let playbackAPI = MockPlaybackAPI()
        let transferCompleted = AsyncSignal()
        playbackAPI.onTransferPlaybackCompleted = { _, _ in
            transferCompleted.signal()
        }
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: staleDevice,
            isPlaying: true
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.autoResumeOnNextReady = true
        viewModel.handle(.ready(deviceID: "new-spotiglass"))

        let didCompleteTransfer = await transferCompleted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didCompleteTransfer,
            "startup auto-resume should complete its transfer"
        )
        XCTAssertTrue(playbackAPI.actions.contains("transfer:new-spotiglass:true"))
        XCTAssertEqual(
            playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            1,
            "Startup auto-resume should reuse the initial transport snapshot."
        )
    }

    func testAutoResumePreservesPausedStateFromStaleSpotiglassDevice() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: staleDevice,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "new-spotiglass"
        viewModel.setConnectionState(.ready(deviceID: "new-spotiglass"))

        await viewModel.autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: "new-spotiglass")

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:new-spotiglass:false"]
        )
    }

    func testAutoResumePreservesPlayingStateFromStaleSpotiglassDevice() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: staleDevice,
            isPlaying: true
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "new-spotiglass"
        viewModel.setConnectionState(.ready(deviceID: "new-spotiglass"))

        await viewModel.autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: "new-spotiglass")

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:new-spotiglass:true"]
        )
    }

    func testAutoResumeDoesNotUsePlayingStateFromDifferentActiveDevice() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        let otherDevice = SpotifyConnectDevice(
            deviceID: "other-device",
            isActive: true,
            isRestricted: false,
            name: "Other",
            type: "speaker"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: otherDevice,
            isPlaying: true
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "new-spotiglass"
        viewModel.setConnectionState(.ready(deviceID: "new-spotiglass"))

        await viewModel.autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: "new-spotiglass")

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:new-spotiglass:false"]
        )
    }

    func testAutoResumeUsesSafePauseWhenPlayerSnapshotIsAbsent() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.snapshotResponses = [nil]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "new-spotiglass"
        viewModel.setConnectionState(.ready(deviceID: "new-spotiglass"))

        await viewModel.autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: "new-spotiglass")

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:new-spotiglass:false"]
        )
    }

    func testAutoResumeUsesSafePauseWhenPlayerSnapshotReadFails() async {
        let playbackAPI = MockPlaybackAPI()
        let staleDevice = SpotifyConnectDevice(
            deviceID: "stale-spotiglass",
            isActive: true,
            isRestricted: false,
            name: SpotifyPlaybackHost.deviceName,
            type: "computer"
        )
        playbackAPI.availableDevices = [staleDevice]
        playbackAPI.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "new-spotiglass"
        viewModel.setConnectionState(.ready(deviceID: "new-spotiglass"))

        await viewModel.autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: "new-spotiglass")

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer:") },
            ["transfer:new-spotiglass:false"]
        )
    }

    func testRefreshConnectDevicesSkipsNetworkInsideFreshnessWindow() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "a", isActive: false, isRestricted: false, name: "Mac", type: "computer")
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(5)
        )

        await viewModel.refreshConnectDevices()
        await viewModel.refreshConnectDevices()

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 1, "A second refresh inside freshness window should reuse cached device list.")
    }

    func testRefreshConnectDevicesCoalescesConcurrentRequests() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.fetchAvailableDevicesDelayNanoseconds = 80_000_000
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "a", isActive: false, isRestricted: false, name: "Mac", type: "computer")
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(0)
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await viewModel.refreshConnectDevices() }
            group.addTask { await viewModel.refreshConnectDevices() }
        }

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 1, "Concurrent refresh callers should share one in-flight devices request.")
    }

    func testTransferPlaybackForcesDeviceRefreshOutsideFreshnessWindow() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "target", isActive: false, isRestricted: false, name: "Speaker", type: "speaker")
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(30)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.refreshConnectDevices()
        await viewModel.transferPlayback(toConnectDevice: "target")

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 2, "Post-transfer refresh should bypass short-term freshness TTL.")
    }

    func testStaleTransportSnapshotCannotReplaceSelectedConnectDevice() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "sdk-device",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer"
            ),
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "sdk-device"
        viewModel.setActivePlaybackDeviceID("sdk-device")
        viewModel.connectDevices = [SpotifyConnectDevice(
            deviceID: "living-room",
            isActive: false,
            isRestricted: false,
            name: "Living Room",
            type: "speaker"
        )]

        await viewModel.transferPlayback(toConnectDevice: "living-room")

        XCTAssertEqual(viewModel.activePlaybackDeviceID, "living-room")
    }

    func testConnectTransferMakesNextCommandUseSelectedDevice() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "living-room",
                isActive: false,
                isRestricted: false,
                name: "Living Room",
                type: "speaker"
            )
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero
        )
        viewModel.handle(.ready(deviceID: "sdk-device"))
        await viewModel.refreshConnectDevices(force: true)

        await viewModel.transferPlayback(toConnectDevice: "living-room")
        await viewModel.next()

        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("next:") },
            ["next:living-room"],
            "Commands after a Connect transfer must target the selected active device."
        )
    }

    func testConnectTransferRoutesSupportedCommandsToSelectedDevice() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "living-room",
                isActive: false,
                isRestricted: false,
                name: "Living Room",
                type: "speaker"
            )
        ]
        let seekSent = AsyncSignal()
        playbackAPI.onSeek = { _ in seekSent.signal() }
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: commander,
            postShuffleSyncDelay: .seconds(10),
            postRepeatSyncDelay: .seconds(10),
            skipCommandMinimumSpacing: .zero
        )
        viewModel.handle(.ready(deviceID: "sdk-device"))
        await viewModel.refreshConnectDevices(force: true)
        await viewModel.transferPlayback(toConnectDevice: "living-room")

        await viewModel.next()
        await viewModel.previous()
        await viewModel.seek(to: 12_000)
        let didSeek = await seekSent.wait(timeout: .seconds(1))
        await viewModel.cycleRepeat()
        await viewModel.toggleShuffle()
        let queue = QueueViewModel(playbackAPI: playbackAPI, playbackSession: viewModel)
        await queue.addToQueue(uri: "spotify:track:queued")
        await viewModel.play(uri: "spotify:track:played")
        await viewModel.togglePlayPause()

        XCTAssertTrue(didSeek)
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("next:") }, ["next:living-room"])
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("previous:") }, ["previous:living-room"])
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("seek:") }, ["seek:living-room:12000"])
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("setRepeat:") }, ["setRepeat:living-room:context"])
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("setShuffle:") }, ["setShuffle:living-room:true"])
        XCTAssertTrue(playbackAPI.actions.contains("addToQueue:living-room:spotify:track:queued"))
        XCTAssertTrue(playbackAPI.actions.contains("play:living-room:spotify:track:played"))
        XCTAssertFalse(playbackAPI.actions.contains("transfer:sdk-device:false"))
        XCTAssertTrue(commander.commands.filter { $0.command == .togglePlay }.isEmpty)
    }

    // MARK: - Skip command (previous/next) spam guard

    func testPreviousBurstWithinCooldownIssuesSinglePOST() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .seconds(60)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        for _ in 0..<5 {
            await viewModel.previous()
        }

        XCTAssertEqual(
            playbackAPI.actions,
            ["previous:device-1"],
            "Burst-presses within the skip cooldown window must coalesce to a single POST /v1/me/player/previous."
        )
        XCTAssertFalse(viewModel.isSkipCommandPending)
    }

    func testNextAndPreviousShareSkipCooldownGate() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .seconds(60)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.previous()
        await viewModel.next()
        await viewModel.previous()
        await viewModel.next()

        XCTAssertEqual(
            playbackAPI.actions,
            ["previous:device-1"],
            "Previous and Next must share the gate so a Prev → Next → Prev burst cannot stack POSTs."
        )
    }

    func testSkipCommandsAreReleasedOnceCooldownElapses() async throws {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .milliseconds(500)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.previous()
        await viewModel.previous()
        let previousActionsAfterBurst = playbackAPI.actions.filter { $0.hasPrefix("previous:") }
        XCTAssertEqual(
            previousActionsAfterBurst.count,
            1,
            "Burst within the cooldown should result in exactly one POST."
        )

        viewModel.lastSkipDispatchInstant = viewModel.clock.now.advanced(by: .seconds(-1))

        await viewModel.previous()
        let previousActionsAfterCooldown = playbackAPI.actions.filter { $0.hasPrefix("previous:") }
        XCTAssertEqual(
            previousActionsAfterCooldown,
            ["previous:device-1", "previous:device-1"],
            "Once the spacing window has elapsed, a fresh press should reach Spotify again."
        )
    }

    func testNextUsesLiveURIWhenStateChangedByAnotherAuthoritativePath() async {
        let playbackAPI = MockPlaybackAPI()
        let nextStarted = AsyncSignal()
        let releaseNext = AsyncSignal()
        playbackAPI.onNext = {
            nextStarted.signal()
            await releaseNext.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:old"
        )
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:new"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstNext = Task { await viewModel.next() }
        await nextStarted.wait()
        // This path updates the live now-playing URI without calling
        // observeSkipAdvance(_:), so completion must compare the dispatch's
        // captured URI against currentNowPlayingURI as a secondary fence.
        viewModel.setConnectionState(.playing(newTrack))
        releaseNext.signal()
        await firstNext.value

        await viewModel.next()

        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
    }

    func testNextDoesNotRearmLockAfterSDKAdvanceDuringREST() async {
        let playbackAPI = MockPlaybackAPI()
        let nextStarted = AsyncSignal()
        let releaseNext = AsyncSignal()
        playbackAPI.onNext = {
            nextStarted.signal()
            await releaseNext.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:old"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstNext = Task { await viewModel.next() }
        await nextStarted.wait()
        viewModel.handle(.stateChanged(
            oldTrack.with(positionMilliseconds: 0),
            isPaused: false,
            nextTracks: []
        ))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "New",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:new"
            ),
            isPaused: false,
            nextTracks: []
        ))
        releaseNext.signal()
        await firstNext.value

        await viewModel.next()

        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
        XCTAssertTrue(viewModel.isNextCommandLockedOut)
    }

    func testFailedNextClearsDispatchWithoutLeavingLockState() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.nextError = URLError(.notConnectedToInternet)
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.next()

        XCTAssertFalse(viewModel.isSkipCommandPending)
        XCTAssertFalse(viewModel.isNextCommandLockedOut)
        XCTAssertNil(viewModel.pendingSkipDispatch)
        guard case .error = viewModel.connectionState else {
            return XCTFail("A failed skip should publish its playback error")
        }
    }

    func testDisconnectDuringInFlightNextClearsLateLockState() async {
        let playbackAPI = MockPlaybackAPI()
        let nextStarted = AsyncSignal()
        let releaseNext = AsyncSignal()
        playbackAPI.onNext = {
            nextStarted.signal()
            await releaseNext.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        let nextTask = Task { await viewModel.next() }
        await nextStarted.wait()
        await viewModel.disconnect()
        releaseNext.signal()
        await nextTask.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(viewModel.isSkipCommandPending)
        XCTAssertFalse(viewModel.isNextCommandLockedOut)
        XCTAssertNil(viewModel.pendingSkipDispatch)
    }

    func testNextTracksAdvanceWhenThereWasNoPreRequestURI() async {
        let playbackAPI = MockPlaybackAPI()
        let nextStarted = AsyncSignal()
        let releaseNext = AsyncSignal()
        playbackAPI.onNext = {
            nextStarted.signal()
            await releaseNext.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        let firstNext = Task { await viewModel.next() }
        await nextStarted.wait()
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "New",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:new"
            ),
            isPaused: false,
            nextTracks: []
        ))
        releaseNext.signal()
        await firstNext.value

        await viewModel.next()

        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
    }

    func testPreviousPreservesAnUnresolvedNextLockout() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.next()
        await viewModel.previous()
        await viewModel.next()

        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 1)
        XCTAssertEqual(playbackAPI.actions.filter { $0 == "previous:device-1" }.count, 1)
        XCTAssertTrue(viewModel.isNextCommandLockedOut)
    }

    func testNextLocksOutUntilPlaybackURIAdvances() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 5_000,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.next()
        await viewModel.next()
        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 1)
        XCTAssertEqual(viewModel.nextCommandDroppedLockoutCount, 1)

        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "New",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:new"
            ),
            isPaused: false,
            nextTracks: []
        ))
        await viewModel.next()
        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
    }

    func testNextLockoutTimeoutEventuallyAllowsAnotherDispatch() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .milliseconds(40)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 5_000,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.next()
        await viewModel.next()
        viewModel.pendingNextSkipLockout?.lockoutDeadline = viewModel.clock.now
        await viewModel.next()

        XCTAssertGreaterThanOrEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
        XCTAssertGreaterThanOrEqual(viewModel.nextCommandTimeoutUnlockCount, 1)
    }

    // MARK: - Transfer playback hardening (audit follow-up)

    func testDisconnectDuringKnownDeviceRetryIgnoresLifecycleCancellation() async {
        let playbackAPI = MockPlaybackAPI()
        let transferStarted = AsyncSignal()
        let releaseTransfer = AsyncSignal()
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
            await releaseTransfer.wait()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.playbackError("retry me"))

        let retryTask = Task {
            await viewModel.retryPlaybackTransfer()
        }
        let didStart = await transferStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)

        await viewModel.disconnect()
        releaseTransfer.signal()
        await retryTask.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNil(viewModel.connectionStateError)
    }

    func testDisconnectDuringPlayEnsureTransferDoesNotPublishCancellationError() async {
        let playbackAPI = MockPlaybackAPI()
        let transferStarted = AsyncSignal()
        let releaseTransfer = AsyncSignal()
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
            await releaseTransfer.wait()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        let playTask = Task {
            await viewModel.play(uri: "spotify:track:1")
        }
        let didStart = await transferStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)

        await viewModel.disconnect()
        releaseTransfer.signal()
        await playTask.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(viewModel.connectionStateError != nil)
        XCTAssertFalse(playbackAPI.actions.contains { $0.hasPrefix("play:") })
    }

    func testDisconnectDuringInFlightTransferSuppressesLateCompletionWork() async {
        let playbackAPI = MockPlaybackAPI()
        let transferStarted = AsyncSignal()
        let releaseTransfer = AsyncSignal()
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
            await releaseTransfer.wait()
        }
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "target",
                isActive: false,
                isRestricted: false,
                name: "Speaker",
                type: "speaker"
            )
        ]
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        let transferTask = Task {
            await viewModel.transferPlayback(toConnectDevice: "target")
        }
        let didStart = await transferStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)

        await viewModel.disconnect()
        releaseTransfer.signal()
        await transferTask.value
        await Task.yield()

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNil(viewModel.activePlaybackDeviceID)
        XCTAssertTrue(viewModel.connectDevices.isEmpty)
        XCTAssertFalse(playbackAPI.actions.contains("fetchAvailableDevices"))
    }

    func testDisconnectCancelsQueuedTransferIntentAfterInFlightTransfer() async {
        let playbackAPI = MockPlaybackAPI()
        let transferStarted = AsyncSignal()
        let releaseTransfer = AsyncSignal()
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
            await releaseTransfer.wait()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        let firstTransfer = Task {
            await viewModel.transferPlayback(toConnectDevice: "target-a")
        }
        let didStart = await transferStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        let queuedTransfer = Task {
            await viewModel.transferPlayback(toConnectDevice: "target-b")
        }
        await Task.yield()

        await viewModel.disconnect()
        releaseTransfer.signal()
        await firstTransfer.value
        await queuedTransfer.value

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(playbackAPI.actions.contains { $0.contains("target-b") })
    }

    func testConcurrentPlayRequestsCollapseToASingleTransferPUT() async {
        let playbackAPI = MockPlaybackAPI()
        let transferStarted = AsyncSignal()
        playbackAPI.onTransferPlayback = { _, _ in
            transferStarted.signal()
        }
        // Stretch the transfer enough that two `play()` calls overlap the in-flight PUT.
        playbackAPI.transferPlaybackDelayNanoseconds = 150_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        let didStartTransfer = await transferStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartTransfer,
            "the first play should enter transfer before the second starts"
        )
        async let second: Void = viewModel.play(uri: "spotify:track:2")
        _ = await (first, second)

        let transferActions = playbackAPI.actions.filter { $0.hasPrefix("transfer") }
        XCTAssertEqual(
            transferActions,
            ["transfer:device-1:false"],
            "Concurrent `play()` calls must funnel through a single in-flight transfer PUT."
        )
        let playActions = playbackAPI.actions.filter { $0.hasPrefix("play:") }
        XCTAssertEqual(playActions.count, 2, "Both play requests should still issue their own /v1/me/player/play call.")
    }

    func testEnsurePlaybackSkipsTransferWhenSnapshotShowsTargetDeviceActive() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.activeConnectDevice = SpotifyConnectDevice(
            deviceID: "device-1",
            isActive: true,
            isRestricted: false,
            name: "Spotiglass",
            type: "computer"
        )
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        // Prime `latestPlayerSnapshot` so the idempotency check reads a fresh active device.
        await viewModel.syncTransportFromSpotify()

        await viewModel.play(uri: "spotify:track:1")

        XCTAssertFalse(
            playbackAPI.actions.contains { $0.hasPrefix("transfer") },
            "When Spotify already reports the local device active, `play(uri:)` must not issue PUT /v1/me/player."
        )
        XCTAssertTrue(playbackAPI.actions.contains("play:device-1:spotify:track:1"))
    }

    func testManualConnectTransferSkipsWhenTargetDeviceIsAlreadyActive() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "device-other",
                isActive: true,
                isRestricted: false,
                name: "Other",
                type: "speaker"
            )
        ]
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        // Connect picker reads `connectDevices`; populate it before the manual transfer.
        await viewModel.refreshConnectDevices(force: true)

        await viewModel.transferPlayback(toConnectDevice: "device-other")

        XCTAssertFalse(
            playbackAPI.actions.contains(where: { $0.hasPrefix("transfer:") }),
            "Picking the already-active Connect device must not issue another PUT /v1/me/player."
        )
    }

    func testRateLimitedTransferSetsCooldownAndShortCircuitsImmediateRetry() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.transferPlaybackErrors = [SpotifyAPIError.rateLimited(retryAfter: 5)]
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")

        // First attempt issues PUT and records the 429 cooldown.
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("transfer") }, ["transfer-error:device-1:false"])

        await viewModel.retryPlaybackTransfer()

        // Within cooldown, the retry must short-circuit and not call the API again.
        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer") },
            ["transfer-error:device-1:false"],
            "Retry within Spotify's Retry-After window must not re-issue PUT /v1/me/player."
        )
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected .error after rate-limited retry")
        }
        XCTAssertEqual(displayError.recoveryAction, .retryTransfer)
    }

    func testAutomaticTransferBudgetBlocksFurtherRetriesAfterCap() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            autoTransferRollingWindow: .seconds(60),
            autoTransferRollingWindowMax: 2
        )

        // Burn the auto-transfer budget with two successful ensure-before-play cycles.
        for index in 0..<2 {
            viewModel.handle(.ready(deviceID: "device-1"))
            await viewModel.play(uri: "spotify:track:\(index)")
            viewModel.handle(.notReady(deviceID: "device-1"))
        }
        // The third cycle should be rejected by the rolling-window budget.
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.play(uri: "spotify:track:2")

        let transferCount = playbackAPI.actions.filter { $0.hasPrefix("transfer") }.count
        XCTAssertEqual(
            transferCount, 2,
            "Automatic ensure-before-play transfers must stop after the rolling-window cap is reached."
        )
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected .error after the budget rejected the third automatic transfer")
        }
        XCTAssertEqual(displayError.recoveryAction, .retryTransfer)
    }
}
