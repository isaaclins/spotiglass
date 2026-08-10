import Foundation

/// One timed line from LRC / LRCLIB `syncedLyrics` text.
struct SyncedLyricLine: Equatable, Identifiable, Codable {
    let id: Int
    let startTimeMs: Int
    let words: String
}

enum LrcLineParser {
    /// Parses standard LRC lines with leading `[mm:ss]` or `[mm:ss.xx]` / `[mm:ss.xxx]` timestamps.
    static func parseSyncedLines(_ lrc: String) -> [SyncedLyricLine] {
        var result: [SyncedLyricLine] = []
        var nextID = 0
        for raw in lrc.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let (ms, text) = extractLeadingTimestamp(trimmed), !text.isEmpty else { continue }
            result.append(SyncedLyricLine(id: nextID, startTimeMs: ms, words: text))
            nextID += 1
        }
        return result.sorted { $0.startTimeMs < $1.startTimeMs }.enumerated().map { index, line in
            SyncedLyricLine(id: index, startTimeMs: line.startTimeMs, words: line.words)
        }
    }

    /// Applies the user's manual lyric sync nudge to a raw playback position.
    ///
    /// A positive `offsetMs` advances lyric selection (lines appear earlier, to
    /// compensate for the usual fetch/playback-report lag); a negative value
    /// delays it. The result is floored at zero so the very first line never
    /// gets skipped by a large negative offset.
    static func effectivePositionMs(positionMs: Int, offsetMs: Int) -> Int {
        max(0, positionMs + offsetMs)
    }

    /// Last line whose `startTimeMs` is at or before `positionMs` (clamped).
    static func activeTimedLineIndex(positionMs: Int, lines: [SyncedLyricLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        var index = 0
        for i in lines.indices {
            if lines[i].startTimeMs <= positionMs {
                index = i
            } else {
                break
            }
        }
        return index
    }

    /// When only plain lyrics exist, advance the highlight proportionally through the track.
    static func activePlainLineIndex(positionMs: Int, durationMs: Int, lineCount: Int) -> Int {
        guard lineCount > 0 else { return 0 }
        let duration = max(durationMs, 1)
        let progress = min(1, max(0, Double(positionMs) / Double(duration)))
        return min(lineCount - 1, Int(progress * Double(lineCount)))
    }

    private static func extractLeadingTimestamp(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
            return nil
        }
        let tag = String(line[line.startIndex...close])
        guard let ms = parseTimestampTag(tag) else {
            return nil
        }
        let after = line.index(after: close)
        guard after < line.endIndex else {
            return (ms, "")
        }
        let remainder = String(line[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ms, remainder)
    }

    /// Parses `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`, `[mm:ss.xxx]` (fraction is sub-second; 1–3 digits).
    private static func parseTimestampTag(_ tag: String) -> Int? {
        let inner = tag.dropFirst().dropLast()
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
            let minutes = Int(parts[0]),
            let secondsWhole = Int(parts[1].split(separator: ".", omittingEmptySubsequences: false).first ?? "")
        else {
            return nil
        }

        let secPart = String(parts[1])
        let fractional: String?
        if let dot = secPart.firstIndex(of: ".") {
            fractional = String(secPart[secPart.index(after: dot)...])
        } else {
            fractional = nil
        }

        let subMs = fractionalMilliseconds(fractional)
        let baseMs = (minutes * 60 + secondsWhole) * 1_000
        return baseMs + subMs
    }

    private static func fractionalMilliseconds(_ fractional: String?) -> Int {
        guard let fractional, !fractional.isEmpty else {
            return 0
        }
        let trimmed = fractional.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed.prefix(3)) else {
            return 0
        }
        switch trimmed.count {
        case 1:
            return n * 100
        case 2:
            return n * 10
        default:
            return min(n, 999)
        }
    }
}
