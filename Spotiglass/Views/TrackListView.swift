import SwiftUI

/// Native track collection used by playlist-like detail surfaces.
///
/// `List` on macOS is backed by `NSTableView`, so it virtualizes rows itself:
/// only the rows inside the clip view plus a small reuse margin are ever
/// realized, which is the property the previous hand written virtualizer
/// existed to provide. Handing the job back to the framework also brings the
/// table behaviors the custom scroll view had to fake or go without: click to
/// select, shift-click to extend a range, command-click to toggle, selection
/// that de-emphasizes when the window stops being key, arrow key navigation,
/// and a focus ring on the row a context menu was opened on.
///
/// Optional header and footer content lets a detail surface keep its metadata
/// and release shelves in the same native collection instead of nesting a
/// selectable table inside another scroll view.
struct TrackListView<Row: View>: View {
    let tracks: [TrackRowViewModel]
    /// Bound straight through to the browser view model's selection set, which
    /// stays the source of truth every context menu action reads.
    @Binding var selection: Set<String>
    let rowBuilder: (TrackRowViewModel) -> Row
    /// Optional content rendered above the track rows in the native list.
    let headerContent: AnyView?
    /// Optional content rendered below the track rows in the native list.
    let footerContent: AnyView?
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
    /// Drag-to-reorder (#543): the table's own move, with its insertion line and the selected
    /// rows moving together. `nil` offers no reordering at all (Liked Songs, albums, other
    /// people's playlists). Rows stay draggable to the sidebar either way.
    var moveRows: ((IndexSet, Int) -> Void)? = nil

    init(
        tracks: [TrackRowViewModel],
        selection: Binding<Set<String>>,
        rowBuilder: @escaping (TrackRowViewModel) -> Row,
        pendingScrollRestoreTrackID: Binding<String?>,
        onFirstVisibleTrackChanged: @escaping (String) -> Void,
        playSelection: ((Set<String>) -> Void)? = nil,
        moveRows: ((IndexSet, Int) -> Void)? = nil,
        headerContent: AnyView? = nil,
        footerContent: AnyView? = nil
    ) {
        self.tracks = tracks
        _selection = selection
        self.rowBuilder = rowBuilder
        self.headerContent = headerContent
        self.footerContent = footerContent
        _pendingScrollRestoreTrackID = pendingScrollRestoreTrackID
        self.onFirstVisibleTrackChanged = onFirstVisibleTrackChanged
        self.playSelection = playSelection
        self.moveRows = moveRows
    }

    /// Deliberately a reference type rather than stored-in-state values. Rows
    /// report every time the table realizes or drops one, and keeping that in
    /// view state would invalidate the body on each report, re-walking the whole
    /// track array to redraw nothing. Nobody observes this bookkeeping.
    @State private var realizedRows = TrackListRealizedRows()

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if let headerContent {
                    headerContent
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                ForEach(tracks) { track in
                    rowBuilder(track)
                        .frame(height: TrackListRow.listRowHeight)
                        // With the list's own inset the row's edge lands on the
                        // page margin, under the header's artwork and titles.
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: SpotiglassDesign.Layout.insetListContentInset,
                            bottom: 0,
                            trailing: SpotiglassDesign.Layout.insetListContentInset
                        ))
                        .tag(track.id)
                        // Row lifecycle is what tells us where the list is. Deriving
                        // it from the scroll offset instead reads the wrong row,
                        // because NSTableView estimates the height of rows it has
                        // not measured yet, so a jump down a long playlist leaves
                        // the offset covering more rows than the arithmetic thinks.
                        // onScrollVisibilityChange would be the precise answer but
                        // it never fires inside a macOS List, so this settles for the
                        // table's realized rows, which run one row wide of the
                        // visible ones. The consumer wants an approximation.
                        .onAppear { setRowRealized(true, track: track) }
                        .onDisappear { setRowRealized(false, track: track) }
                }
                .onMove(perform: moveRows)

                if let footerContent {
                    footerContent
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .onKeyPress(.return) {
                guard let playSelection, !selection.isEmpty else { return .ignored }
                playSelection(selection)
                return .handled
            }
            // Rows that change places (a reorder) don't appear again, so the topmost one is
            // worked out anew from the rows' new order.
            .onChange(of: tracks, initial: true) {
                realizedRows.positionByTrackID = TrackListVisibility.positions(of: tracks)
                reportFirstVisibleTrack()
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
            realizedRows.trackIDs.insert(track.id)
        } else {
            realizedRows.trackIDs.remove(track.id)
        }
        reportFirstVisibleTrack()
    }

    private func reportFirstVisibleTrack() {
        guard let id = TrackListVisibility.firstVisibleTrackID(realized: realizedRows.trackIDs, positions: realizedRows.positionByTrackID),
              id != realizedRows.lastReportedFirstVisibleTrackID
        else { return }
        realizedRows.lastReportedFirstVisibleTrackID = id
        onFirstVisibleTrackChanged(id)
    }
}

/// Ids of the rows the table currently has realized. A table only realizes what
/// it draws, so this stays about a viewport deep however long the playlist is.
/// Kept by id, not row number: a row dragged to a new spot keeps its identity and
/// doesn't appear again, so a number recorded for it would go stale (#543).
@MainActor
final class TrackListRealizedRows {
    var trackIDs: Set<String> = []
    /// Each row's place in the list, built again when the rows change.
    var positionByTrackID: [String: Int] = [:]
    var lastReportedFirstVisibleTrackID: String?
}

/// Picks the topmost row out of the rows the table currently has on hand, by
/// their places in the list as it is now. Only the realized rows are looked at,
/// about a viewport of them, however long the list.
enum TrackListVisibility {
    static func positions(of tracks: [TrackRowViewModel]) -> [String: Int] {
        Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    static func firstVisibleTrackID(realized: Set<String>, positions: [String: Int]) -> String? {
        realized.min { (positions[$0] ?? .max, $0) < (positions[$1] ?? .max, $1) }
    }
}
