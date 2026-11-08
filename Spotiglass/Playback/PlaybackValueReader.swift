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

    /// The mark of `track`, given the URI its list marks as playing. Only the playing row carries
    /// the play state: a row that isn't playing looks the same whether the player plays or not,
    /// so play/pause leaves it alone.
    static func resolve(
        track: TrackRowViewModel,
        markedURI: String?,
        connectionState: PlaybackConnectionState
    ) -> TrackRowPlaybackMark {
        guard let uri = track.playableURI, uri == markedURI else { return .notPlaying }
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

    /// The marks of the rows of one list. Build it once per list and hand it to each of its rows.
    func marks(in rows: [TrackRowViewModel]) -> TrackListPlaybackMarks {
        TrackListPlaybackMarks(rows: rows, connectionState: connectionState, connectionStateChanges: connectionStateChanges)
    }
}

/// Which row of one list is playing, worked out once per change of the player and shared by all
/// of the list's rows. An Apple Music song started from another list is found by title, artists
/// and length among all the rows (#396); done by each row, one pause on a list of 1000 songs
/// cost about 0.3 to 0.5 s on the main thread.
@MainActor
final class TrackListPlaybackMarks {
    private let rows: [TrackRowViewModel]
    private let connectionState: @MainActor () -> PlaybackConnectionState
    private let connectionStateChanges: AnyPublisher<PlaybackConnectionState, Never>
    /// The URI the rows mark as playing, and the state it was worked out for.
    private var resolved: (state: PlaybackConnectionState, markedURI: String?)?

    fileprivate init(
        rows: [TrackRowViewModel],
        connectionState: @escaping @MainActor () -> PlaybackConnectionState,
        connectionStateChanges: AnyPublisher<PlaybackConnectionState, Never>
    ) {
        self.rows = rows
        self.connectionState = connectionState
        self.connectionStateChanges = connectionStateChanges
    }

    private func mark(of track: TrackRowViewModel) -> TrackRowPlaybackMark {
        mark(of: track, connectionState: connectionState())
    }

    /// The row for `track`, built with its mark and built again only when the mark changes.
    func row<Row: View>(
        for track: TrackRowViewModel,
        @ViewBuilder content: @escaping (TrackRowPlaybackMark) -> Row
    ) -> PlaybackValueReader<TrackRowPlaybackMark, Row> {
        PlaybackValueReader(
            value: { [self] in mark(of: track) },
            changes: connectionStateChanges
                .map { [self] in mark(of: track, connectionState: $0) }
                .eraseToAnyPublisher(),
            content: content
        )
    }

    private func mark(of track: TrackRowViewModel, connectionState: PlaybackConnectionState) -> TrackRowPlaybackMark {
        TrackRowPlaybackMark.resolve(
            track: track,
            markedURI: markedURI(connectionState: connectionState),
            connectionState: connectionState
        )
    }

    private func markedURI(connectionState: PlaybackConnectionState) -> String? {
        // The position doesn't change which row plays.
        let state = connectionState.ignoringPosition
        if let resolved, resolved.state == state { return resolved.markedURI }
        #if DEBUG
        ViewBodyTally.record("TrackListPlaybackMarks.markedURI")
        #endif
        // An Apple Music song started from another list carries that list's id (#396).
        let markedURI = PlaylistBrowserPlaybackHelpers.rowURI(
            markedAs: PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: state),
            connectionState: state,
            rows: rows
        )
        resolved = (state, markedURI)
        return markedURI
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
