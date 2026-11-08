import Combine
import Foundation
import SwiftUI

/// Where the playing track is. Kept apart from ``PlaybackSessionViewModel`` because it changes
/// with every update from the player: only the views that show the position (the progress bar,
/// the lyrics) observe it, so a new position doesn't re-render the track list, the sidebar and
/// the menus (#409).
@MainActor
final class PlaybackProgressModel: ObservableObject {
    @Published var anchor: PlaybackProgressAnchor?
}

/// Hands its content the current position anchor and re-renders only that content when the
/// player reports a new position, not the view around it (#409).
struct PlaybackProgressReader<Content: View>: View {
    @ObservedObject var progress: PlaybackProgressModel
    @ViewBuilder let content: (PlaybackProgressAnchor?) -> Content

    var body: some View {
        content(progress.anchor)
    }
}

@MainActor
extension PlaybackSessionViewModel {
    func reanchorProgress(from nowPlaying: PlaybackNowPlaying?, isAdvancing: Bool) {
        guard let nowPlaying, nowPlaying.durationMilliseconds > 0 else {
            progressAnchor = nil
            return
        }
        progressAnchor = PlaybackProgressAnchor(
            positionMilliseconds: nowPlaying.positionMilliseconds,
            anchorDate: Date(),
            durationMilliseconds: nowPlaying.durationMilliseconds,
            isAdvancing: isAdvancing
        )
    }

    func syncProgressAnchorWithConnectionState() {
        switch connectionState {
        case let .playing(nowPlaying):
            reanchorProgress(from: nowPlaying, isAdvancing: true)
        case let .paused(nowPlaying):
            reanchorProgress(from: nowPlaying, isAdvancing: false)
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            progressAnchor = nil
        }
    }
}
