import SwiftUI

// MARK: - Sectioned results list

struct CommandPaletteSectionedListView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]
    let accessibilityReduceMotion: Bool

    /// Height of the rows; starts at the cap so the first frame never collapses the list.
    @State private var contentHeight = SpotiglassDesign.Layout.paletteResultsHeight

    /// When results reload but `selectedIndex` stays `0`, `onChange(of: selectedIndex)` does not fire — use this signature to scroll the first row back into view.
    private var paletteResultsScrollSignature: String {
        viewModel.visibleItems.map(\.id).joined(separator: "\u{1e}")
    }

    private typealias Row = CommandPaletteListRow

    var body: some View {
        let rows = CommandPaletteListRow.rows(for: sections)
        // "Show all results" stays under the list, so a short window can't scroll it away (#462).
        let scrolling = rows.filter { $0.section != .showAll }
        let pinned = rows.filter { $0.section == .showAll }

        VStack(spacing: 0) {
            if !scrolling.isEmpty {
                ScrollViewReader { proxy in
                    // As tall as its rows up to the cap, and shorter still when the window is:
                    // the list scrolls instead of pushing the filters and the footer out (#462).
                    ScrollView(.vertical) {
                        sectionStack(scrolling)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: min(contentHeight, SpotiglassDesign.Layout.paletteResultsHeight))
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        scrollPaletteSelectionToIndex(proxy: proxy, index: newIndex, rows: rows)
                    }
                    .onChange(of: paletteResultsScrollSignature) { _, _ in
                        scrollPaletteSelectionToIndex(proxy: proxy, index: viewModel.selectedIndex, rows: rows)
                    }
                    .onAppear {
                        scrollPaletteSelectionToIndex(proxy: proxy, index: viewModel.selectedIndex, rows: rows)
                    }
                }
            }
            if !pinned.isEmpty {
                if !scrolling.isEmpty {
                    Divider()
                }
                VStack(spacing: 0) {
                    ForEach(pinned) { row in
                        resultRow(row)
                    }
                }
                .padding(SpotiglassDesign.spacingXS)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Lazy, so a long uncapped list ("Here" in a big playlist) builds and loads artwork only for
    /// the rows on screen. A short list is built whole, so its measured height is exact; a long
    /// one is taller than the cap either way.
    ///
    /// One flat `ForEach` whose rows are named by the item they show, not by their place. Named by
    /// place, inside one `ForEach` per section, the lazy stack kept drawing the old rows when the
    /// sections changed under them (All → Tracks, results → idle list), while the highlight and
    /// Return went by the new list (#499).
    private func sectionStack(_ rows: [Row]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.startsSection {
                    sectionHeader(row.section, isFirst: row.flatIndex == rows.first?.flatIndex)
                }
                resultRow(row)
            }
        }
        .padding(SpotiglassDesign.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ section: CommandPaletteSection, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
            // Title case, no letter spacing: section headers no longer render in all caps.
            Text(section.displayLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if section == .recentSearches {
                CommandPaletteClearRecentsButton(viewModel: viewModel)
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingS)
        .padding(.top, isFirst ? SpotiglassDesign.spacingXS : SpotiglassDesign.spacingS)
        .padding(.bottom, SpotiglassDesign.spacingXXS)
    }

    private func resultRow(_ row: Row) -> some View {
        let isSelected = row.flatIndex == viewModel.selectedIndex
        return CommandPaletteResultRowView(item: row.item, isSelected: isSelected)
            .padding(.horizontal, SpotiglassDesign.spacingS)
            .padding(.vertical, SpotiglassDesign.spacingXXS)
            .background {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectedIndex = row.flatIndex
                Task { await viewModel.executeSelection() }
            }
            .accessibilityAction {
                viewModel.selectedIndex = row.flatIndex
                Task { await viewModel.executeSelection() }
            }
    }

    /// Scrolls to the row ``CommandPaletteViewModel/selectedIndex`` points at (flat ``visibleItems`` order).
    private func scrollPaletteSelectionToIndex(proxy: ScrollViewProxy, index: Int, rows: [Row]) {
        guard rows.indices.contains(index) else { return }
        let id = rows[index].id
        let scroll = {
            if accessibilityReduceMotion {
                proxy.scrollTo(id, anchor: .center)
            } else {
                withAnimation(.smooth(duration: 0.22)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        DispatchQueue.main.async {
            scroll()
        }
    }
}

/// One result in the palette's list: the item, its place in ``CommandPaletteViewModel/visibleItems``
/// and a name that stays with the item, so a row is only ever reused for the item it showed.
struct CommandPaletteListRow: Identifiable {
    let id: String
    let flatIndex: Int
    let item: CommandPaletteItem
    /// The section the row is listed under. Not always the item's own: the idle list shows
    /// commands under Quick actions.
    let section: CommandPaletteSection
    /// The first row of its section, which draws the section's heading above itself.
    let startsSection: Bool

    static func rows(for sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]) -> [Self] {
        var rows: [Self] = []
        var seen: [String: Int] = [:]
        for entry in sections {
            for (offset, item) in entry.items.enumerated() {
                // Section and item id; the same item twice in one list gets a count, so no two
                // rows share a name.
                let base = "\(entry.section.rawValue)\u{1f}\(item.id)"
                let count = seen[base, default: 0]
                seen[base] = count + 1
                rows.append(Self(
                    id: count == 0 ? base : "\(base)\u{1f}\(count)",
                    flatIndex: rows.count,
                    item: item,
                    section: entry.section,
                    startsSection: offset == 0
                ))
            }
        }
        return rows
    }
}

struct CommandPaletteResultRowView: View {
    let item: CommandPaletteItem
    /// The arrow keys move a background colour today. Assistive technology reads
    /// no colour, so the selection has to be stated as a trait (#119).
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            CommandPaletteRowLeadingView(item: item)
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingHalf) {
                HStack(spacing: SpotiglassDesign.spacingXS) {
                    Text(item.title)
                        .lineLimit(1)
                    if item.isExplicit {
                        Text(SpotiglassL10n.string("palette.explicit"))
                            .font(.caption2.weight(.medium))
                            .padding(SpotiglassDesign.Layout.badgeInsets)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, SpotiglassDesign.spacingXXS)
        // One element per result instead of icon plus title plus "Explicit" plus
        // subtitle as separate fragments (#119).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        #if DEBUG
        .onAppear { ViewBodyTally.appeared("CommandPaletteResultRow:\(item.id)") }
        .onDisappear { ViewBodyTally.disappeared("CommandPaletteResultRow:\(item.id)") }
        .onChange(of: item.id) { old, new in
            ViewBodyTally.disappeared("CommandPaletteResultRow:\(old)")
            ViewBodyTally.appeared("CommandPaletteResultRow:\(new)")
        }
        #endif
    }

    /// One sentence per result: title, the explicit badge, then the subtitle.
    static func accessibilityLabel(for item: CommandPaletteItem) -> String {
        var parts = [item.title]
        if item.isExplicit {
            parts.append(SpotiglassL10n.string("palette.explicit"))
        }
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        return parts.joined(separator: SpotiglassL10n.string("common.comma"))
    }
}

struct CommandPaletteRowLeadingView: View {
    let item: CommandPaletteItem

    var body: some View {
        if item.section == .artists {
            CommandPaletteArtistAvatar(
                imageURL: item.artistAvatarURL,
                fallbackSystemName: item.iconSystemName
            )
        } else if let url = item.trackArtworkURL {
            CommandPaletteTrackArtwork(
                imageURL: url,
                fallbackSystemName: item.iconSystemName
            )
        } else {
            // As wide as the artwork other rows lead with, so every title starts on one line.
            Image(systemName: item.iconSystemName)
                .frame(width: SpotiglassDesign.Layout.smallArtworkSize)
                .foregroundStyle(.secondary)
        }
    }
}

/// Forgets the recent searches, from the heading of their section.
struct CommandPaletteClearRecentsButton: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @State private var isHovering = false

    var body: some View {
        Button(SpotiglassL10n.string("palette.recentSearches.clear")) {
            viewModel.clearRecentSearches()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .accessibilityLabel(SpotiglassL10n.string("palette.recentSearches.clear.accessibility"))
    }
}
