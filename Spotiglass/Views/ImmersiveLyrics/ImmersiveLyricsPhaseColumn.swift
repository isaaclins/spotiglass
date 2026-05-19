import SwiftUI

struct ImmersiveLyricsLyricsPhaseColumn: View {
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let currentTrack: PlaybackNowPlaying?
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize
    let maxHeight: CGFloat

    var body: some View {
        Group {
            switch lyricsModel.phase {
            case .idle:
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .loading:
                ProgressView(String(localized: "lyrics.loading"))
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
                        Button(String(localized: "lyrics.tryAgain")) {
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
                    lyricsTextSize: lyricsTextSize
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

    var body: some View {
        switch lyrics {
        case .instrumental:
            Text("lyrics.instrumental", bundle: .main)
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
                lyricsTextSize: lyricsTextSize
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
