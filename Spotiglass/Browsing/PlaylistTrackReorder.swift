import Foundation

/// The arithmetic of dragging rows to a new spot in a playlist (#543), kept apart from the views
/// and the services so it can be checked on its own.
enum PlaylistTrackReorder {
    /// The new order after the rows at `moving` (current positions, zero-based) are dropped
    /// before the row at `offset` (a position in the current list; `count` drops them at the
    /// end), the way `List` drops rows: the moved rows keep their order among themselves and
    /// land together. Returns `order[i]` = the current position of the row that goes to `i`.
    static func order(count: Int, moving: Set<Int>, toOffset offset: Int) -> [Int] {
        let moved = moving.filter { (0..<count).contains($0) }.sorted()
        let clampedOffset = min(max(0, offset), count)
        let before = (0..<clampedOffset).filter { !moving.contains($0) }
        let after = (clampedOffset..<count).filter { !moving.contains($0) }
        return before + moved + after
    }

    static func isUnchanged(_ order: [Int]) -> Bool {
        order.enumerated().allSatisfy { $0.offset == $0.element }
    }

    // MARK: - Spotify

    /// Spotify's reorder requests that turn the current order into `order`, one contiguous run of
    /// moved rows per request. Each request counts positions in the playlist as the requests
    /// before it left it, the way Spotify applies them one after another.
    static func rangeMoves(for order: [Int]) -> [MusicPlaylistRangeMove] {
        guard !isUnchanged(order) else { return [] }
        // The rows that stay put are the longest run of the new order that is still in its old
        // order; the rest move. Spotify moves a contiguous range per request, so the moved rows
        // go in runs of rows that were already neighbours and stay neighbours.
        let stays = longestIncreasingSubsequence(order)
        var working = Array(0..<order.count)
        var moves: [MusicPlaylistRangeMove] = []
        var index = 0
        while index < order.count {
            guard !stays.contains(order[index]) else {
                index += 1
                continue
            }
            // A run: rows next to each other in the new order that were neighbours before.
            var length = 1
            while index + length < order.count,
                  !stays.contains(order[index + length]),
                  order[index + length] == order[index + length - 1] + 1 {
                length += 1
            }
            let start = working.firstIndex(of: order[index])!
            // The run goes right after the row before it in the new order, or to the top.
            let insertBefore = index == 0 ? 0 : working.firstIndex(of: order[index - 1])! + 1
            if insertBefore != start {
                moves.append(MusicPlaylistRangeMove(rangeStart: start, rangeLength: length, insertBefore: insertBefore))
                apply(moves[moves.count - 1], to: &working)
            }
            index += length
        }
        return moves
    }

    /// Applies one Spotify range move to a list, the way Spotify does: `insertBefore` names a
    /// position from before the move.
    static func apply<Element>(_ move: MusicPlaylistRangeMove, to list: inout [Element]) {
        let range = move.rangeStart..<(move.rangeStart + move.rangeLength)
        let run = Array(list[range])
        list.removeSubrange(range)
        let destination = move.insertBefore > move.rangeStart ? move.insertBefore - move.rangeLength : move.insertBefore
        list.insert(contentsOf: run, at: destination)
    }

    // MARK: - Music app

    /// The current positions of the rows Music has to move, in the order to move them. Music's
    /// scripting moves a track inside its playlist only to the end, so the rows that stay are
    /// the longest start of the new order that is still in its old order, and every row after
    /// them goes to the end in turn.
    static func moveToEndSequence(for order: [Int]) -> [Int] {
        guard !isUnchanged(order) else { return [] }
        // The rows that stay are the ones left once the others went to the end, in their old
        // order, so they must be a start of the new order that is still in the old order.
        var kept = 0
        while kept < order.count, kept == 0 || order[kept] > order[kept - 1] {
            kept += 1
        }
        return Array(order[kept...])
    }

    /// The positions of the longest increasing run (not necessarily contiguous) of `values`.
    private static func longestIncreasingSubsequence(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []
        var tailIndices: [Int] = []
        var previous = Array(repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if tails[mid] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tailIndices[low - 1] }
            if low == tails.count {
                tails.append(value)
                tailIndices.append(index)
            } else {
                tails[low] = value
                tailIndices[low] = index
            }
        }
        var result: Set<Int> = []
        var cursor = tailIndices.last ?? -1
        while cursor >= 0 {
            result.insert(values[cursor])
            cursor = previous[cursor]
        }
        return result
    }
}
