import XCTest

@testable import Spotiglass

final class PlaybackOutputSFResolverTests: XCTestCase {
    func testAirPodsMaxKeywordOrdering() {
        let candidates = PlaybackOutputSFResolver.symbolCandidates(
            deviceName: "Isaacs AirPods Max", spotifyDeviceType: nil)
        XCTAssertEqual(candidates.first, "airpodsmax")
    }

    func testHomePodMiniBeforeHomePod() {
        let mini = PlaybackOutputSFResolver.symbolCandidates(
            deviceName: "Living Room HomePod mini", spotifyDeviceType: nil)
        XCTAssertEqual(mini.first, "homepod.mini.fill")

        let full = PlaybackOutputSFResolver.symbolCandidates(deviceName: "Kitchen HomePod", spotifyDeviceType: nil)
        XCTAssertEqual(full.first, "homepod.fill")
    }

    func testSpeakerTypeFallback() {
        let candidates = PlaybackOutputSFResolver.symbolCandidates(deviceName: "", spotifyDeviceType: "speaker")
        XCTAssertEqual(candidates.first, "hifispeaker.fill")
    }

    func testUnknownInputEndsWithHeadphonesCandidate() {
        let candidates = PlaybackOutputSFResolver.symbolCandidates(
            deviceName: "Obscure Bluetooth Thing", spotifyDeviceType: nil)
        XCTAssertEqual(candidates, ["headphones"])
    }

    func testLeftEarHintUsesSideVariantsFirst() {
        let candidates = PlaybackOutputSFResolver.symbolCandidates(
            deviceName: "AirPods Pro (Left)", spotifyDeviceType: nil)
        XCTAssertEqual(candidates.first, "airpods.left")
    }
}
