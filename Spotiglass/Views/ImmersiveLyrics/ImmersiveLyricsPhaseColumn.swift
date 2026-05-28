import SwiftUI

struct ImmersiveLyricsLyricsPhaseColumn: View {
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let currentTrack: PlaybackNowPlaying?
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize
    let maxHeight: CGFloat
    /// Forwarded down to synced-lyrics rows so tapping a line seeks playback.
    /// nil → lines remain non-interactive (current behaviour for callers that
    /// don't supply a seek action).
    var onSeek: ((Int) -> Void)? = nil

    var body: some View {
        Group {
            switch lyricsModel.phase {
            case .idle:
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .loading:
                ProgressView(SpotiglassL10n.string("lyrics.loading"))
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                    if let track = currentTrack {
                        Button(SpotiglassL10n.string("lyrics.tryAgain")) {
                            Task { await lyricsModel.load(track: track) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case let .ready(lyrics):
                ImmersiveLyricsReadyContentView(
                    lyrics: lyrics,
                    maxHeight: maxHeight,
                    positionMs: positionMs,
                    trackDurationMs: currentTrack?.durationMilliseconds,
                    reduceMotion: reduceMotion,
                    usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                    lyricsTextSize: lyricsTextSize,
                    onSeek: onSeek
                )
            }
        }
    }
}

struct ImmersiveLyricsReadyContentView: View {
    let lyrics: FetchedLyrics
    let maxHeight: CGFloat
    let positionMs: Int
    let trackDurationMs: Int?
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize
    var onSeek: ((Int) -> Void)? = nil

    var body: some View {
        switch lyrics {
        case .instrumental:
            Text(SpotiglassL10n.string("lyrics.instrumental"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        case let .synced(lines):
            ImmersiveLyricsTimedLyricsScrollView(
                lines: lines,
                maxHeight: maxHeight,
                positionMs: positionMs,
                reduceMotion: reduceMotion,
                usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                lyricsTextSize: lyricsTextSize,
                onSeek: onSeek
            )
        case let .unsyncedPlain(lines):
            ImmersiveLyricsPlainLyricsScrollView(
                lines: lines,
                maxHeight: maxHeight,
                positionMs: positionMs,
                trackDurationMs: trackDurationMs,
                reduceMotion: reduceMotion,
                usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                lyricsTextSize: lyricsTextSize
            )
        }
    }
}
