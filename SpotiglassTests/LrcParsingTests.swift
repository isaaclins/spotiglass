import XCTest

@testable import Spotiglass

final class LrcParsingTests: XCTestCase {
    func testParsesSimpleLRC() {
        let lrc = """
        [00:12.00]First line
        [00:15.50]Second line
        """
        let lines = LrcLineParser.parseSyncedLines(lrc)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startTimeMs, 12_000)
        XCTAssertEqual(lines[0].words, "First line")
        XCTAssertEqual(lines[1].startTimeMs, 15_500)
        XCTAssertEqual(lines[1].words, "Second line")
    }

    func testParsesThreeDigitFractional() {
        let lrc = "[00:01.234]Subsecond"
        let lines = LrcLineParser.parseSyncedLines(lrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].startTimeMs, 1_234)
        XCTAssertEqual(lines[0].words, "Subsecond")
    }

    func testParsesMinuteBoundary() {
        let lrc = "[01:02.03]Chorus"
        let lines = LrcLineParser.parseSyncedLines(lrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].startTimeMs, 62_030)
    }

    func testSkipsMetadataAndEmptyLines() {
        let lrc = """
        [ar:Artist]
        [00:05.00]Real lyric

        """
        let lines = LrcLineParser.parseSyncedLines(lrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words, "Real lyric")
    }

    func testActiveTimedLineIndex() {
        let lines = [
            SyncedLyricLine(id: 0, startTimeMs: 0, words: "A"),
            SyncedLyricLine(id: 1, startTimeMs: 5_000, words: "B"),
            SyncedLyricLine(id: 2, startTimeMs: 10_000, words: "C")
        ]
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: 0, lines: lines), 0)
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: 4_999, lines: lines), 0)
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: 5_000, lines: lines), 1)
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: 99_000, lines: lines), 2)
    }

    func testEffectivePositionOffsetShiftsActiveLine() {
        let lines = [
            SyncedLyricLine(id: 0, startTimeMs: 0, words: "A"),
            SyncedLyricLine(id: 1, startTimeMs: 5_000, words: "B"),
            SyncedLyricLine(id: 2, startTimeMs: 10_000, words: "C")
        ]
        // At 4.6s the raw active line is still A; a +0.5s "earlier" nudge crosses into B.
        let raw = 4_600
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: raw, lines: lines), 0)
        let earlier = LrcLineParser.effectivePositionMs(positionMs: raw, offsetMs: 500)
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: earlier, lines: lines), 1)
        // A negative nudge holds the previous line a little longer.
        let later = LrcLineParser.effectivePositionMs(positionMs: 5_200, offsetMs: -500)
        XCTAssertEqual(LrcLineParser.activeTimedLineIndex(positionMs: later, lines: lines), 0)
    }

    func testEffectivePositionFloorsAtZero() {
        XCTAssertEqual(LrcLineParser.effectivePositionMs(positionMs: 200, offsetMs: -2_000), 0)
        XCTAssertEqual(LrcLineParser.effectivePositionMs(positionMs: 0, offsetMs: 0), 0)
        XCTAssertEqual(LrcLineParser.effectivePositionMs(positionMs: 1_000, offsetMs: 500), 1_500)
    }

    func testAppearanceSettingsDefaultsOffsetToZeroForLegacyFiles() throws {
        // Older settings.json predates the offset key entirely.
        let legacy = Data(#"{"colorScheme":"dark"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: legacy)
        XCTAssertEqual(decoded.lyricsOffsetMilliseconds, 0)
    }

    func testAppearanceSettingsClampsOutOfRangeOffset() throws {
        let tooHigh = Data(#"{"lyricsOffsetMilliseconds":999999}"#.utf8)
        let tooLow = Data(#"{"lyricsOffsetMilliseconds":-999999}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(AppearanceSettings.self, from: tooHigh).lyricsOffsetMilliseconds,
            AppearanceSettings.lyricsOffsetLimitMs
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AppearanceSettings.self, from: tooLow).lyricsOffsetMilliseconds,
            -AppearanceSettings.lyricsOffsetLimitMs
        )
        // In-range values survive untouched.
        XCTAssertEqual(AppearanceSettings(lyricsOffsetMilliseconds: 500).lyricsOffsetMilliseconds, 500)
    }

    func testActivePlainLineIndex() {
        XCTAssertEqual(LrcLineParser.activePlainLineIndex(positionMs: 0, durationMs: 100_000, lineCount: 4), 0)
        XCTAssertEqual(LrcLineParser.activePlainLineIndex(positionMs: 24_999, durationMs: 100_000, lineCount: 4), 0)
        XCTAssertEqual(LrcLineParser.activePlainLineIndex(positionMs: 25_000, durationMs: 100_000, lineCount: 4), 1)
        XCTAssertEqual(LrcLineParser.activePlainLineIndex(positionMs: 100_000, durationMs: 100_000, lineCount: 4), 3)
    }

    func testSpotifyTrackIDForLyrics() {
        let track = PlaybackNowPlaying(
            name: "T",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123"
        )
        XCTAssertEqual(track.spotifyTrackIDForLyrics, "abc123")
        XCTAssertNil(
            PlaybackNowPlaying(
                name: "E",
                artists: ["P"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 60_000,
                positionMilliseconds: 0,
                uri: "spotify:episode:xyz"
            ).spotifyTrackIDForLyrics
        )
    }
}
