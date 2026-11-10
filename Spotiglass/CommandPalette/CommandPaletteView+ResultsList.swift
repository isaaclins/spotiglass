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

    private typealias Row = (flatIndex: Int, item: CommandPaletteItem)

    var body: some View {
        var running = 0
        let chunks: [(section: CommandPaletteSection, rows: [Row])] = sections.map { entry in
            let rows: [Row] = entry.items.map { item in
                defer { running += 1 }
                return (flatIndex: running, item: item)
            }
            return (entry.section, rows)
        }
        // "Show all results" stays under the list, so a short window can't scroll it away (#462).
        let scrolling = chunks.filter { $0.section != .showAll }
        let pinned = chunks.first { $0.section == .showAll }?.rows ?? []

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
                        scrollPaletteSelectionToIndex(proxy: proxy, index: newIndex)
                    }
                    .onChange(of: paletteResultsScrollSignature) { _, _ in
                        scrollPaletteSelectionToIndex(proxy: proxy, index: viewModel.selectedIndex)
                    }
                    .onAppear {
                        scrollPaletteSelectionToIndex(proxy: proxy, index: viewModel.selectedIndex)
                    }
                }
            }
            if !pinned.isEmpty {
                if !scrolling.isEmpty {
                    Divider()
                }
                VStack(spacing: 0) {
                    ForEach(pinned, id: \.flatIndex) { row in
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
    private func sectionStack(_ chunks: [(section: CommandPaletteSection, rows: [Row])]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { sectionIndex, chunk in
                HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                    // Title case, no letter spacing: section headers no longer render in all caps.
                    Text(chunk.section.displayLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if chunk.section == .recentSearches {
                        CommandPaletteClearRecentsButton(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, SpotiglassDesign.spacingS)
                .padding(.top, sectionIndex == 0 ? SpotiglassDesign.spacingXS : SpotiglassDesign.spacingS)
                .padding(.bottom, SpotiglassDesign.spacingXXS)
                ForEach(chunk.rows, id: \.flatIndex) { row in
                    resultRow(row)
                }
            }
        }
        .padding(SpotiglassDesign.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .id(CommandPaletteRowScrollIDs.id(flatIndex: row.flatIndex))
            .onTapGesture {
                viewModel.selectedIndex = row.flatIndex
                Task { await viewModel.executeSelection() }
            }
            .accessibilityAction {
                viewModel.selectedIndex = row.flatIndex
                Task { await viewModel.executeSelection() }
            }
    }

    /// Stable ids for ``ScrollViewReader`` / `scrollTo`; aligned with ``CommandPaletteViewModel/selectedIndex`` (flat ``visibleItems`` order).
    private func scrollPaletteSelectionToIndex(proxy: ScrollViewProxy, index: Int) {
        guard viewModel.visibleItems.indices.contains(index) else { return }
        let id = CommandPaletteRowScrollIDs.id(flatIndex: index)
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

enum CommandPaletteRowScrollIDs {
    static func id(flatIndex: Int) -> String {
        "palette-result-\(flatIndex)"
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
