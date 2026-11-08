import Combine
import SwiftUI

/// Shows `content` with one value read from the player, and runs it again only when that value
/// changes.
///
/// Observing the whole player session re-ran every observer on each play/pause and each new
/// track: the browser, the sidebar, the detail column and every visible track and playlist row,
/// though only the playing rows looked any different (#422). A row reads its own value through
/// this instead, so a change of the player re-runs only the rows whose value changed.
struct PlaybackValueReader<Value: Equatable, Content: View>: View {
    private let value: () -> Value
    private let changes: AnyPublisher<Value, Never>
    private let content: (Value) -> Content
    /// The value the body last showed. Setting a different one re-runs the body.
    @State private var shown: Value

    /// - Parameters:
    ///   - value: The value now.
    ///   - changes: The value after each change of the player; repeats are ignored.
    init(
        value: @escaping () -> Value,
        changes: AnyPublisher<Value, Never>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.value = value
        self.changes = changes
        self.content = content
        _shown = State(initialValue: value())
    }

    var body: some View {
        // Read fresh rather than from `shown`, so a parent that hands in new rows is never one
        // change behind. Reading `shown` is what ties this body to the player.
        let _ = shown
        content(value())
            .onReceive(changes) { newValue in
                if newValue != shown { shown = newValue }
            }
    }
}

/// Whether a track row is the one playing, and whether it plays or is paused.
struct TrackRowPlaybackMark: Equatable {
    var isCurrent: Bool
    var isPlaying: Bool

    static let notPlaying = TrackRowPlaybackMark(isCurrent: false, isPlaying: false)

    /// The mark of `track` in a list of `rows`, given the player's state. Only the playing row
    /// carries the play state: a row that isn't playing looks the same whether the player plays
    /// or not, so play/pause leaves it alone.
    static func resolve(
        track: TrackRowViewModel,
        rows: [TrackRowViewModel],
        connectionState: PlaybackConnectionState
    ) -> TrackRowPlaybackMark {
        guard let uri = track.playableURI else { return .notPlaying }
        // An Apple Music song started from another list carries that list's id (#396).
        let markedURI = PlaylistBrowserPlaybackHelpers.rowURI(
            markedAs: PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: connectionState),
            connectionState: connectionState,
            rows: rows
        )
        guard uri == markedURI else { return .notPlaying }
        return TrackRowPlaybackMark(
            isCurrent: true,
            isPlaying: PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState)
        )
    }
}

/// Where track rows read the player's state from (#422).
@MainActor
struct TrackRowPlaybackSource {
    private let connectionState: @MainActor () -> PlaybackConnectionState
    private let connectionStateChanges: AnyPublisher<PlaybackConnectionState, Never>

    init(session: PlaybackSessionViewModel) {
        connectionState = { [weak session] in session?.connectionState ?? .disconnected }
        connectionStateChanges = session.connectionStatePublisher
    }

    func mark(of track: TrackRowViewModel, in rows: [TrackRowViewModel]) -> TrackRowPlaybackMark {
        TrackRowPlaybackMark.resolve(track: track, rows: rows, connectionState: connectionState())
    }

    /// The row for `track`, built with its mark and built again only when the mark changes.
    func row<Row: View>(
        for track: TrackRowViewModel,
        in rows: [TrackRowViewModel],
        @ViewBuilder content: @escaping (TrackRowPlaybackMark) -> Row
    ) -> PlaybackValueReader<TrackRowPlaybackMark, Row> {
        PlaybackValueReader(
            value: { mark(of: track, in: rows) },
            changes: connectionStateChanges
                .map { TrackRowPlaybackMark.resolve(track: track, rows: rows, connectionState: $0) }
                .eraseToAnyPublisher(),
            content: content
        )
    }
}

/// Whether a sidebar playlist is the one playing, and whether it plays or is paused.
struct PlaylistRowPlaybackMark: Equatable {
    var isActive: Bool
    var isPlaying: Bool

    static func resolve(
        playlistID: String,
        activePlaylistID: String?,
        connectionState: PlaybackConnectionState
    ) -> PlaylistRowPlaybackMark {
        let isActive = playlistID == activePlaylistID
        return PlaylistRowPlaybackMark(
            isActive: isActive,
            isPlaying: isActive && PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState)
        )
    }
}

extension PlaybackSessionViewModel {
    /// The sidebar row for `playlistID`, built with its mark and built again only when the mark
    /// changes (#422).
    func playlistRow<Row: View>(
        _ playlistID: String,
        @ViewBuilder content: @escaping (PlaylistRowPlaybackMark) -> Row
    ) -> PlaybackValueReader<PlaylistRowPlaybackMark, Row> {
        PlaybackValueReader(
            value: { [weak self] in
                PlaylistRowPlaybackMark.resolve(
                    playlistID: playlistID,
                    activePlaylistID: self?.activePlaylistID,
                    connectionState: self?.connectionState ?? .disconnected
                )
            },
            // `$activePlaylistID` announces the new id before storing it, so the mark is built
            // from what the publishers deliver, not read back from the session.
            changes: Publishers.CombineLatest($activePlaylistID, connectionStatePublisher)
                .map { activePlaylistID, connectionState in
                    PlaylistRowPlaybackMark.resolve(
                        playlistID: playlistID,
                        activePlaylistID: activePlaylistID,
                        connectionState: connectionState
                    )
                }
                .eraseToAnyPublisher(),
            content: content
        )
    }
}
