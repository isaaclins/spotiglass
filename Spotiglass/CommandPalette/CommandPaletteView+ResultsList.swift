import SwiftUI

// MARK: - Sectioned results list

struct CommandPaletteSectionedListView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]
    let accessibilityReduceMotion: Bool

    /// When results reload but `selectedIndex` stays `0`, `onChange(of: selectedIndex)` does not fire — use this signature to scroll the first row back into view.
    private var paletteResultsScrollSignature: String {
        viewModel.visibleItems.map(\.id).joined(separator: "\u{1e}")
    }

    var body: some View {
        let sectionChunks: [(section: CommandPaletteSection, rows: [(flatIndex: Int, item: CommandPaletteItem)])] = {
            var running = 0
            return sections.map { entry in
                let rows: [(flatIndex: Int, item: CommandPaletteItem)] = entry.items.map { item in
                    let idx = running
                    running += 1
                    return (flatIndex: idx, item: item)
                }
                return (entry.section, rows)
            }
        }()

        ScrollViewReader { proxy in
            List {
                ForEach(Array(sectionChunks.enumerated()), id: \.offset) { sectionIndex, chunk in
                    Section {
                        ForEach(chunk.rows, id: \.flatIndex) { row in
                            CommandPaletteResultRowView(
                                item: row.item,
                                isSelected: row.flatIndex == viewModel.selectedIndex
                            )
                                .id(CommandPaletteRowScrollIDs.id(flatIndex: row.flatIndex))
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowBackground(row.flatIndex == viewModel.selectedIndex ? Color.primary.opacity(0.12) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.selectedIndex = row.flatIndex
                                    Task { await viewModel.executeSelection() }
                                }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            // Title case, no letter spacing. Tracking existed to
                            // make shouted all-caps labels readable, and section
                            // headers no longer render in all caps.
                            Text(chunk.section.displayLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, sectionIndex == 0 ? 0 : 4)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            // Arrow keys are handled by `CommandPaletteEventMonitor`; keep keyboard focus on the query field for typing.
            .focusable(false)
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
        .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SpotiglassDesign.spacingXS) {
                    Text(item.title)
                        .lineLimit(1)
                    if item.isExplicit {
                        Text(SpotiglassL10n.string("palette.explicit"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
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
        .padding(.vertical, 4)
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
            Image(systemName: item.iconSystemName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
        }
    }
}
