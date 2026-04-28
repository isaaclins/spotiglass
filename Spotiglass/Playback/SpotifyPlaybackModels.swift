import Foundation

enum PlaybackConnectionState: Equatable {
    case disconnected
    case connecting
    case ready(deviceID: String)
    case transferring(deviceID: String)
    case playing(PlaybackNowPlaying)
    case paused(PlaybackNowPlaying?)
    case unavailable(String)
    case error(PlaybackDisplayError)
}

struct PlaybackNowPlaying: Equatable {
    let name: String
    let artists: [String]
    let albumArtURL: URL?
    let durationMilliseconds: Int
    let positionMilliseconds: Int
    let uri: String?

    var artistText: String {
        artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ")
    }

    var progressText: String {
        "\(Self.durationText(milliseconds: positionMilliseconds)) / \(Self.durationText(milliseconds: durationMilliseconds))"
    }

    static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

struct PlaybackDisplayError: Error, Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: PlaybackRecoveryAction?

    static func == (lhs: PlaybackDisplayError, rhs: PlaybackDisplayError) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.recoveryAction == rhs.recoveryAction
    }
}

enum PlaybackRecoveryAction: Equatable {
    case reconnect
    case reauthenticate
    case retryTransfer
}

enum PlaybackBridgeEvent: Equatable {
    case ready(deviceID: String)
    case notReady(deviceID: String)
    case stateChanged(PlaybackNowPlaying?, isPaused: Bool)
    case initializationError(String)
    case authenticationError(String)
    case accountError(String)
    case playbackError(String)
    case log(String)
}

enum PlaybackBridgeCommand: String, Equatable {
    case connect
    case disconnect
    case togglePlay
    case pause
    case resume
    case seek
    case next
    case previous
    case playURI
}

enum PlaybackBridgeMessageError: Error, Equatable {
    case invalidEnvelope
    case missingPayload(String)
    case unsupportedEvent(String)
}
