import SwiftUI

// MARK: - Footer

/// The quiet bottom row of the panel: the keys that work right now, and how to switch scope.
struct CommandPaletteFooterView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel

    var body: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            CommandPaletteHintsChipView(viewModel: viewModel)
            Spacer(minLength: SpotiglassDesign.spacingS)
            CommandPaletteCommandsHintChipView(scope: viewModel.currentScope)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CommandPaletteHintsChipView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingM) {
            Text(SpotiglassL10n.string("palette.footer.navigate"))
            Text(SpotiglassL10n.string("palette.footer.run"))
            if viewModel.currentScope == .songs {
                Text(SpotiglassL10n.string("palette.footer.filter"))
            }
            if viewModel.canEnqueueSelectedItem {
                Text(SpotiglassL10n.string("palette.footer.queue"))
            }
            if viewModel.canPinSelectedItem {
                Text(SpotiglassL10n.string("palette.footer.pin"))
            }
            Text(SpotiglassL10n.string("palette.footer.close"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Search scope says how to reach the commands; command scope says how to get back to search.
struct CommandPaletteCommandsHintChipView: View {
    let scope: CommandPaletteScope

    var body: some View {
        switch scope {
        case .songs:
            Text(SpotiglassL10n.string("palette.footer.commandsHint"))
        case .commands:
            (Text(SpotiglassL10n.string("palette.footer.searchHintPrefix"))
                + Text(SpotiglassL10n.string("palette.footer.searchPrefix")).foregroundStyle(.primary)
                + Text(SpotiglassL10n.format("palette.footer.searchHintSuffix", MusicServiceSelection.current.displayName)))
                .truncationMode(.head)
        }
    }
}

// MARK: - Filters

struct CommandPaletteCategoryPillsRowView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel

    var body: some View {
        // Every chip keeps its whole label: when the row is wider than the panel it scrolls
        // instead of squeezing a label away (#469).
        ViewThatFits(in: .horizontal) {
            pills
            ScrollView(.horizontal, showsIndicators: false) {
                pills
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SpotiglassL10n.string("palette.category.accessibility"))
    }

    private var pills: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            ForEach(viewModel.availableSearchCategories, id: \.self) { category in
                CommandPaletteCategoryPillView(category: category, viewModel: viewModel)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct CommandPaletteCategoryPillView: View {
    let category: CommandPaletteSearchCategory
    @ObservedObject var viewModel: CommandPaletteViewModel

    var body: some View {
        let isSelected = viewModel.searchCategoryFilter == category
        Button {
            viewModel.selectCategory(category)
        } label: {
            Text(category.segmentLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(CommandPaletteFilterChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(category.segmentLabel)
    }
}

/// A filter chip. The selected one is filled with the accent and labelled with
/// ``SpotiglassDesign/onAccent(appearsActive:)``: a fixed white label vanished on the accent,
/// which turns white while the window is not the active one (#469).
struct CommandPaletteFilterChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        CommandPaletteFilterChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct CommandPaletteFilterChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(labelStyle)
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingXS)
            .background {
                if isSelected {
                    Capsule(style: .continuous).fill(.spotiglassAccent)
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isHovering || configuration.isPressed ? 0.12 : 0.06))
                }
            }
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
    }

    private var labelStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(SpotiglassDesign.onAccent(appearsActive: appearsActive))
            : AnyShapeStyle(.primary)
    }
}
