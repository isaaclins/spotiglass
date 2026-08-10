import SwiftUI

/// Custom virtualizer that mounts only the rows visible inside the scroll
/// viewport plus a small overscan window above and below. Sliding the visible
/// window keeps the per-frame cost O(visible_count + 2 * overscan) regardless
/// of total track count, so resizing a 998-track playlist costs the same as a
/// 6-track one.
struct VirtualizedTrackList: View {
    let tracks: [TrackRowViewModel]
    let rowBuilder: (TrackRowViewModel) -> TrackListRow
    /// Set externally (e.g. when lyrics dismiss) to a track id; the view scrolls
    /// to that row's approximate vertical center, then clears the binding.
    @Binding var pendingScrollRestoreTrackID: String?
    /// Fires with the id of the topmost visible row whenever it changes; powers
    /// the "remember last visible track" behavior used for scroll restore.
    let onFirstVisibleTrackChanged: (String) -> Void

    private static let overscan: Int = 10
    private let rowHeight: CGFloat = TrackListRow.listRowHeight

    @State private var scrollOffsetY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var lastReportedFirstVisibleTrackID: String?

    private var visibleRange: Range<Int> {
        guard !tracks.isEmpty else { return 0..<0 }
        guard viewportHeight > 0 else {
            return 0..<min(tracks.count, Self.overscan)
        }
        let first = max(0, Int(floor(scrollOffsetY / rowHeight)) - Self.overscan)
        let last = min(tracks.count, Int(ceil((scrollOffsetY + viewportHeight) / rowHeight)) + Self.overscan)
        return first..<max(first, last)
    }

    var body: some View {
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(height: CGFloat(tracks.count) * rowHeight)
                ForEach(Array(visibleRange), id: \.self) { index in
                    rowBuilder(tracks[index])
                        .frame(height: rowHeight, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: CGFloat(index) * rowHeight)
                }
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: VirtualGeometry.self) { geometry in
            VirtualGeometry(offsetY: geometry.contentOffset.y, height: geometry.containerSize.height)
        } action: { _, new in
            scrollOffsetY = max(0, new.offsetY)
            viewportHeight = new.height
            reportFirstVisibleIfChanged()
        }
        .onChange(of: pendingScrollRestoreTrackID) { _, newValue in
            guard let id = newValue,
                let index = tracks.firstIndex(where: { $0.id == id })
            else { return }
            let target = max(0, CGFloat(index) * rowHeight - max(0, (viewportHeight - rowHeight) / 2))
            scrollPosition.scrollTo(point: CGPoint(x: 0, y: target))
            pendingScrollRestoreTrackID = nil
        }
    }

    private func reportFirstVisibleIfChanged() {
        guard !tracks.isEmpty else { return }
        let firstVisibleIndex = min(tracks.count - 1, max(0, Int(floor(scrollOffsetY / rowHeight))))
        let id = tracks[firstVisibleIndex].id
        guard id != lastReportedFirstVisibleTrackID else { return }
        lastReportedFirstVisibleTrackID = id
        onFirstVisibleTrackChanged(id)
    }
}

private struct VirtualGeometry: Equatable {
    let offsetY: CGFloat
    let height: CGFloat
}
