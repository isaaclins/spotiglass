import AppKit
import Foundation

/// Maps Spotify Connect device names / macOS audio device names to SF Symbol names with runtime availability checks.
enum PlaybackOutputSFResolver {
    /// Primary symbol for `Image(systemName:)` (first candidate that exists on this macOS).
    static func symbolName(deviceName: String, spotifyDeviceType: String?) -> String {
        firstAvailableSymbol(from: symbolCandidates(deviceName: deviceName, spotifyDeviceType: spotifyDeviceType))
    }

    static func firstAvailableSymbol(from candidates: [String]) -> String {
        for name in candidates {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return "headphones"
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Ordered SF Symbol names to try before fallback (`headphones`). Internal for unit tests.
    static func symbolCandidates(deviceName: String, spotifyDeviceType: String?) -> [String] {
        let haystack = normalized(deviceName)
        let typeLower = spotifyDeviceType.map { normalized($0) } ?? ""

        if haystack.contains("airpod") {
            if earSideHint(haystack) == .left {
                return ["airpods.left", "airpods", "headphones"]
            }
            if earSideHint(haystack) == .right {
                return ["airpods.right", "airpods", "headphones"]
            }
        }

        let airpodsRules: [(String, [String])] = [
            ("airpods max", ["airpodsmax", "headphones"]),
            ("airpods pro", ["airpods.pro", "airpods", "headphones"]),
            ("airpods (4th generation)", ["airpods.gen4", "airpods", "headphones"]),
            ("airpods (3rd generation)", ["airpods.gen3", "airpods", "headphones"]),
            ("airpods 4", ["airpods.gen4", "airpods", "headphones"]),
            ("airpods 3", ["airpods.gen3", "airpods", "headphones"]),
            ("airpods", ["airpods", "headphones"]),
        ]

        for (needle, symbols) in airpodsRules where haystack.contains(needle) {
            return symbols
        }

        if haystack.contains("homepod mini") {
            return ["homepod.mini.fill", "hifispeaker.fill", "headphones"]
        }
        if haystack.contains("homepod") {
            return ["homepod.fill", "hifispeaker.fill", "headphones"]
        }

        if haystack.contains("beats") || haystack.contains("studio bud") || haystack.contains("powerbeats")
            || haystack.contains("beats fit")
        {
            return ["beats.headphones", "headphones"]
        }

        if haystack.contains("macbook") || haystack.contains("imac") || haystack.contains("mac studio")
            || haystack.contains("mac pro") || haystack.contains("mac mini")
        {
            return ["macbook", "laptopcomputer", "headphones"]
        }

        if typeLower == "computer", !haystack.isEmpty {
            return ["macbook", "laptopcomputer", "headphones"]
        }

        if haystack.contains("apple tv") || typeLower == "tv" {
            return ["tv", "headphones"]
        }

        if haystack.contains("carplay") || typeLower == "automobile" {
            return ["car", "headphones"]
        }

        if haystack.contains("iphone") || typeLower == "smartphone" {
            return ["iphone", "headphones"]
        }

        if typeLower == "speaker" {
            return ["hifispeaker.fill", "speaker.wave.3.fill", "headphones"]
        }

        if haystack.contains("speaker") {
            return ["hifispeaker.fill", "speaker.wave.3.fill", "headphones"]
        }

        return ["headphones"]
    }

    private enum EarSide {
        case left, right
    }

    private static func earSideHint(_ haystack: String) -> EarSide? {
        let leftHints = ["(left)", " left", "- left", "left pod", "left airpod", "left ear", " l ear"]
        if leftHints.contains(where: { haystack.contains($0) }) {
            return .left
        }
        let rightHints = ["(right)", " right", "- right", "right pod", "right airpod", "right ear", " r ear"]
        if rightHints.contains(where: { haystack.contains($0) }) {
            return .right
        }
        return nil
    }
}
