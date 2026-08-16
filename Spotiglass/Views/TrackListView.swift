import SwiftUI

/// Playlist track table.
///
/// `List` on macOS is backed by `NSTableView`, so it virtualizes rows itself:
/// only the rows inside the clip view plus a small reuse margin are ever
/// realized, which is the property the previous hand written virtualizer
/// existed to provide. Handing the job back to the framework also brings the
/// table behaviors the custom scroll view had to fake or go without: click to
/// select, shift-click to extend a range, command-click to toggle, selection
/// that de-emphasizes when the window stops being key, arrow key navigation,
/// and a focus ring on the row a context menu was opened on.
struct TrackListView: View {
    let tracks: [TrackRowViewModel]
    /// Bound straight through to the browser view model's selection set, which
    /// stays the source of truth every context menu action reads.
    @Binding var selection: Set<String>
    let rowBuilder: (TrackRowViewModel) -> TrackListRow
    /// Set externally (e.g. when lyrics dismiss) to a track id; the list scrolls
    /// that row to the middle of the viewport, then clears the binding.
    @Binding var pendingScrollRestoreTrackID: String?
    /// Fires with the id of the topmost visible row whenever it changes; powers
    /// the "remember last visible track" behavior used for scroll restore.
    let onFirstVisibleTrackChanged: (String) -> Void
    /// Plays the selected rows. Arrow keys already moved the selection, but
    /// nothing consumed Return, so a keyboard user could highlight a track and
    /// never start it (#122).
    var playSelection: ((Set<String>) -> Void)? = nil

    /// Deliberately a reference type rather than stored-in-state values. Rows
    /// report every time the table realizes or drops one, and keeping that in
    /// view state would invalidate the body on each report, re-walking the whole
    /// track array to redraw nothing. Nobody observes this bookkeeping.
    @State private var realizedRows = TrackListRealizedRows()

    var body: some View {
        ScrollViewReader { proxy in
            List(tracks, selection: $selection) { track in
                rowBuilder(track)
                    .frame(height: TrackListRow.listRowHeight)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: SpotiglassDesign.spacingXS,
                        bottom: 0,
                        trailing: SpotiglassDesign.spacingXS
                    ))
                    // Row lifecycle is what tells us where the list is. Deriving
                    // it from the scroll offset instead reads the wrong row,
                    // because NSTableView estimates the height of rows it has
                    // not measured yet, so a jump down a long playlist leaves
                    // the offset covering more rows than the arithmetic thinks.
                    // onScrollVisibilityChange would be the precise answer but
                    // it never fires inside a macOS List, so this settles for
                    // the table's realized rows, which run one row wide of the
                    // visible ones. The consumer wants an approximation.
                    .onAppear { setRowRealized(true, track: track) }
                    .onDisappear { setRowRealized(false, track: track) }
            }
            .listStyle(.inset)
            .onKeyPress(.return) {
                guard let playSelection, !selection.isEmpty else { return .ignored }
                playSelection(selection)
                return .handled
            }
            .onChange(of: pendingScrollRestoreTrackID) { _, newValue in
                guard let id = newValue else { return }
                if tracks.contains(where: { $0.id == id }) {
                    proxy.scrollTo(id, anchor: .center)
                }
                pendingScrollRestoreTrackID = nil
            }
        }
    }

    private func setRowRealized(_ isRealized: Bool, track: TrackRowViewModel) {
        if isRealized {
            realizedRows.trackIDsByRowNumber[track.listPosition] = track.id
        } else {
            realizedRows.trackIDsByRowNumber.removeValue(forKey: track.listPosition)
        }
        guard let id = TrackListVisibility.firstVisibleTrackID(in: realizedRows.trackIDsByRowNumber),
              id != realizedRows.lastReportedFirstVisibleTrackID
        else { return }
        realizedRows.lastReportedFirstVisibleTrackID = id
        onFirstVisibleTrackChanged(id)
    }
}

/// Ids of the rows the table currently has realized, keyed by row number so the
/// topmost one is simply the smallest key. A table only realizes what it draws,
/// so this stays about a viewport deep however long the playlist is.
@MainActor
final class TrackListRealizedRows {
    var trackIDsByRowNumber: [Int: String] = [:]
    var lastReportedFirstVisibleTrackID: String?
}

/// Picks the topmost row out of the rows the table currently has on hand. Row
/// numbers are `TrackRowViewModel.listPosition`, the 1-based position the row
/// occupies in the list, so the lowest one is the row nearest the top.
enum TrackListVisibility {
    static func firstVisibleTrackID(in realizedTrackIDsByRowNumber: [Int: String]) -> String? {
        guard let topmost = realizedTrackIDsByRowNumber.keys.min() else { return nil }
        return realizedTrackIDsByRowNumber[topmost]
    }
}
