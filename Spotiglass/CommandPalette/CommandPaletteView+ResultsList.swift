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
                            CommandPaletteResultRowView(item: row.item)
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
                            Text(chunk.section.displayLabel)
                                .font(.caption2.weight(.semibold))
                                .tracking(1.2)
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

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            CommandPaletteRowLeadingView(item: item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SpotiglassDesign.spacingXS) {
                    Text(item.title)
                        .lineLimit(1)
                    if item.isExplicit {
                        Text("Explicit")
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
