import XCTest

@testable import Spotiglass

@MainActor
final class PlaybackConnectDevicesAndTransferTests: XCTestCase {
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
        XCTAssertEqual(
            refreshCalls.count, 1, "A second refresh inside freshness window should reuse cached device list.")
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
            SpotifyConnectDevice(
                deviceID: "target", isActive: false, isRestricted: false, name: "Speaker", type: "speaker")
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

        try await Task.sleep(nanoseconds: 600_000_000)

        await viewModel.previous()
        let previousActionsAfterCooldown = playbackAPI.actions.filter { $0.hasPrefix("previous:") }
        XCTAssertEqual(
            previousActionsAfterCooldown,
            ["previous:device-1", "previous:device-1"],
            "Once the spacing window has elapsed, a fresh press should reach Spotify again."
        )
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
        viewModel.handle(
            .stateChanged(
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

        viewModel.handle(
            .stateChanged(
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
        viewModel.handle(
            .stateChanged(
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
        try? await Task.sleep(for: .milliseconds(120))
        await viewModel.next()

        XCTAssertGreaterThanOrEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
        XCTAssertGreaterThanOrEqual(viewModel.nextCommandTimeoutUnlockCount, 1)
    }

    // MARK: - Transfer playback hardening (audit follow-up)

    func testConcurrentPlayRequestsCollapseToASingleTransferPUT() async {
        let playbackAPI = MockPlaybackAPI()
        // Stretch the transfer enough that two `play()` calls overlap the in-flight PUT.
        playbackAPI.transferPlaybackDelayNanoseconds = 150_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        try? await Task.sleep(nanoseconds: 15_000_000)
        async let second: Void = viewModel.play(uri: "spotify:track:2")
        _ = await (first, second)

        let transferActions = playbackAPI.actions.filter { $0.hasPrefix("transfer") }
        XCTAssertEqual(
            transferActions,
            ["transfer:device-1:false"],
            "Concurrent `play()` calls must funnel through a single in-flight transfer PUT."
        )
        let playDeadline = Date().addingTimeInterval(1.5)
        while Date() < playDeadline,
            playbackAPI.actions.filter({ $0.hasPrefix("play:") }).count < 2
        {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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
        try? await Task.sleep(nanoseconds: 50_000_000)

        await viewModel.play(uri: "spotify:track:1")
        try? await Task.sleep(nanoseconds: 50_000_000)

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
        guard case .error(let displayError) = viewModel.connectionState else {
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
        guard case .error(let displayError) = viewModel.connectionState else {
            return XCTFail("Expected .error after the budget rejected the third automatic transfer")
        }
        XCTAssertEqual(displayError.recoveryAction, .retryTransfer)
    }
}
