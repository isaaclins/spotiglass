import XCTest
@testable import Spotiglass

final class WebPlaybackCommandScriptBuilderTests: XCTestCase {
    func testConnectAndTransportScripts() throws {
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .connect).contains("connect()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .disconnect).contains("disconnect()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .togglePlay).contains("togglePlay()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .pause).contains("pause()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .resume).contains("resume()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .next).contains("next()"))
        XCTAssertTrue(try WebPlaybackCommandScriptBuilder.script(for: .previous).contains("previous()"))
    }

    func testSeekPlayURIAndVolumeScripts() throws {
        let seek = try WebPlaybackCommandScriptBuilder.script(for: .seek, payload: ["milliseconds": 12_500])
        XCTAssertTrue(seek.contains("seek(12500)"))

        let playURI = try WebPlaybackCommandScriptBuilder.script(
            for: .playURI,
            payload: ["uri": "spotify:track:abc"]
        )
        XCTAssertTrue(playURI.contains("playURI"))
        XCTAssertTrue(playURI.contains("spotify:track:abc"))

        let volume = try WebPlaybackCommandScriptBuilder.script(for: .setVolume, payload: ["volume": 1.5])
        XCTAssertTrue(volume.contains("setVolume(1.000000)"))

        let intVolume = try WebPlaybackCommandScriptBuilder.script(for: .setVolume, payload: ["volume": 0])
        XCTAssertTrue(intVolume.contains("setVolume(0.000000)"))

        let defaultVolume = try WebPlaybackCommandScriptBuilder.script(for: .setVolume, payload: [:])
        XCTAssertTrue(defaultVolume.contains("setVolume(0.800000)"))
    }
}
