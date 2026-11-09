import Foundation

/// JavaScript snippets sent to the hidden Web Playback host page.
enum WebPlaybackCommandScriptBuilder {
    static func script(for command: PlaybackBridgeCommand, payload: [String: Any] = [:]) throws -> String {
        switch command {
        case .connect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.connect();"
        case .disconnect:
            return "window.spotiglassPlayback && window.spotiglassPlayback.disconnect();"
        case .togglePlay, .pause, .resume:
            // A play / pause press's id comes back with the page's answer (#437).
            let id = (payload["id"] as? NSNumber).map { String($0.uint64Value) } ?? ""
            return "window.spotiglassPlayback && window.spotiglassPlayback.\(command.rawValue)(\(id));"
        case .seek:
            let milliseconds = payload["milliseconds"] as? Int ?? 0
            return "window.spotiglassPlayback && window.spotiglassPlayback.seek(\(milliseconds));"
        case .next:
            return "window.spotiglassPlayback && window.spotiglassPlayback.next();"
        case .previous:
            return "window.spotiglassPlayback && window.spotiglassPlayback.previous();"
        case .playURI:
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return "window.spotiglassPlayback && window.spotiglassPlayback.playURI(\(json).uri);"
        case .setVolume:
            let raw = (payload["volume"] as? NSNumber)?.doubleValue
                ?? (payload["volume"] as? Double)
                ?? (payload["volume"] as? Int).map(Double.init)
                ?? 0.8
            let clamped = min(max(raw, 0), 1)
            let literal = String(format: "%.6f", clamped)
            return "window.spotiglassPlayback && window.spotiglassPlayback.setVolume(\(literal));"
        }
    }
}
