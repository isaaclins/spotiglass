import Foundation
import SwiftUI
import XCTest

@testable import Spotiglass

/// Guards the boundary between the test suite and the real user's preferences.
///
/// The test bundle is hosted in the app, so it inherits the bundle identifier
/// `com.isaaclins.spotiglass`. `UserDefaults.standard` inside a test therefore
/// resolves to the same persistent domain the shipping app reads at launch.
/// A test that wrote `spotify.clientID` overwrote the real stored Spotify client
/// ID with `"test-client"` and signed the user out of the actual app.
///
/// Two layers of protection live here. The behavioral tests exercise the exact
/// paths that used to clobber the real domain and assert it did not move. The
/// structural tests scan the test sources, because the leak was caused by
/// default arguments (`SpotifyAuthSettings(defaults: .standard)` and
/// `PlaybackSessionViewModel(defaults: .standard)`) that make an omission at a
/// call site invisible. A sentinel check only catches paths a test happens to
/// exercise, so the structural scan is what keeps new call sites honest.
final class RealUserDefaultsIsolationTests: XCTestCase {
    private static let guardedKeys = [
        "spotify.clientID",
        "spotify.grantedScope",
        "spotiglass.playbackVolume",
        "queue.panel.visible"
    ]

    private func snapshotRealDomain() -> [String: String] {
        var snapshot: [String: String] = [:]
        for key in Self.guardedKeys {
            let value = UserDefaults.standard.object(forKey: key)
            snapshot[key] = value.map { String(describing: $0) } ?? "<absent>"
        }
        return snapshot
    }

    // MARK: - Behavioral guards

    @MainActor
    func testAuthClientIDWritesDoNotReachTheRealDomain() {
        let before = snapshotRealDomain()

        // The exact shape of RootViewTests and ListDetailViewsTests, the call
        // sites that overwrote the real client ID.
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        auth.clientID = "test-client"

        XCTAssertEqual(snapshotRealDomain(), before, "Setting clientID must not touch the real preferences domain.")
    }

    @MainActor
    func testPlaybackVolumeWritesDoNotReachTheRealDomain() {
        let before = snapshotRealDomain()

        let defaults = makeEphemeralDefaults()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            defaults: defaults
        )
        viewModel.setPlaybackVolume(0.33)

        XCTAssertEqual(defaults.double(forKey: "spotiglass.playbackVolume"), 0.33, accuracy: 0.000_001)
        XCTAssertEqual(snapshotRealDomain(), before, "Persisting volume must not touch the real preferences domain.")
    }

    @MainActor
    func testHostedAppStorageWritesDoNotReachTheRealDomain() {
        let before = snapshotRealDomain()

        ViewTestHost.appStorageDefaults.set(true, forKey: "queue.panel.visible")
        ViewTestHost.host(Text("probe"))

        XCTAssertEqual(snapshotRealDomain(), before, "Hosted @AppStorage must bind to the test suite, not the real domain.")
        ViewTestHost.tearDownAll()
    }

    // MARK: - Structural guards

    private func testSourceFiles() throws -> [(name: String, contents: String)] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let urls = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { directory.appendingPathComponent($0) }
        return try urls.map {
            (name: $0.lastPathComponent, contents: strippingWholeLineComments(try String(contentsOf: $0, encoding: .utf8)))
        }
    }

    /// Blanks out lines that are entirely comment, so prose describing the leak
    /// (including the doc comments in this file and in `ViewTestHost`) is not
    /// mistaken for a call site. Lines holding code are left untouched, so a URL
    /// containing `//` can never mask a real reference.
    private func strippingWholeLineComments(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
                return isComment ? "" : line
            }
            .joined(separator: "\n")
    }

    /// No test may reach `UserDefaults.standard`. Use `makeEphemeralDefaults()`.
    func testNoTestSourceTouchesStandardUserDefaults() throws {
        let allowed: Set<String> = [
            // This file reads the real domain deliberately, to prove it stays put.
            "RealUserDefaultsIsolationTests.swift"
        ]
        var offenders: [String] = []
        for file in try testSourceFiles() where !allowed.contains(file.name) {
            for (index, line) in file.contents.components(separatedBy: .newlines).enumerated()
            where line.contains("UserDefaults.standard") {
                offenders.append("\(file.name):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "These tests reach the real preferences domain. Inject makeEphemeralDefaults() instead: "
                + offenders.joined(separator: ", ")
        )
    }

    /// Every `AuthViewModel` built in a test must inject its settings, because the
    /// initializer defaults to `SpotifyAuthSettings()` on `.standard`.
    func testEveryAuthViewModelConstructionInjectsSettings() throws {
        var offenders: [String] = []
        for file in try testSourceFiles() {
            for (line, argumentList) in constructions(of: "AuthViewModel", in: file.contents)
            where !argumentList.contains("settings:") {
                offenders.append("\(file.name):\(line)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "These AuthViewModel constructions fall back to UserDefaults.standard. "
                + "Pass settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()): "
                + offenders.joined(separator: ", ")
        )
    }

    /// Returns the argument list of every `type(` construction, paren balanced so
    /// multi-line call sites are read whole.
    private func constructions(of type: String, in source: String) -> [(line: Int, arguments: String)] {
        let characters = Array(source)
        let token = Array("\(type)(")
        var results: [(Int, String)] = []
        var index = 0
        var line = 1

        while index < characters.count {
            if characters[index] == "\n" { line += 1 }
            guard index + token.count <= characters.count,
                  Array(characters[index ..< index + token.count]) == token
            else {
                index += 1
                continue
            }
            // Reject suffix matches such as `MockAuthViewModel(`.
            if index > 0, characters[index - 1].isLetter || characters[index - 1] == "_" {
                index += 1
                continue
            }

            var depth = 0
            var cursor = index + token.count - 1
            var arguments = ""
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if depth >= 1 { arguments.append(character) }
                cursor += 1
            }
            results.append((line, arguments))
            index += token.count
        }
        return results
    }
}
