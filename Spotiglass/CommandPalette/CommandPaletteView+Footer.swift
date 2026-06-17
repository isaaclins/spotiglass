import SwiftUI

// MARK: - Footer

struct CommandPaletteFooterView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var paletteGlass: Namespace.ID

    var body: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            CommandPaletteHintsChipView(viewModel: viewModel, paletteGlass: paletteGlass)
            Spacer(minLength: 8)
            if viewModel.currentScope == .commands {
                CommandPaletteCommandsHintChipView(paletteGlass: paletteGlass)
            } else {
                CommandPaletteCategoryPillsRowView(viewModel: viewModel, paletteGlass: paletteGlass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CommandPaletteHintsChipView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var paletteGlass: Namespace.ID

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("palette.footer.navigate"))
            Text(SpotiglassL10n.string("palette.footer.run"))
            Text(SpotiglassL10n.string("palette.footer.close"))
            if viewModel.canEnqueueSelectedItem {
                Text(SpotiglassL10n.string("palette.footer.queue"))
            }
            if viewModel.canPinSelectedItem {
                Text(SpotiglassL10n.string("palette.footer.pin"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .glassEffectID("palette.hints", in: paletteGlass)
    }
}

struct CommandPaletteCommandsHintChipView: View {
    var paletteGlass: Namespace.ID

    var body: some View {
        (Text(SpotiglassL10n.string("palette.footer.searchHintPrefix"))
            + Text(SpotiglassL10n.string("palette.footer.searchPrefix")).foregroundStyle(.tertiary)
            + Text(SpotiglassL10n.string("palette.footer.searchHintSuffix")))
            .multilineTextAlignment(.trailing)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingS)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .glassEffectID("palette.footerTrailing", in: paletteGlass)
    }
}

struct CommandPaletteCategoryPillsRowView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var paletteGlass: Namespace.ID

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            ForEach(viewModel.availableSearchCategories, id: \.self) { category in
                CommandPaletteCategoryPillView(
                    category: category,
                    viewModel: viewModel,
                    paletteGlass: paletteGlass
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SpotiglassL10n.string("palette.category.accessibility"))
    }
}

struct CommandPaletteCategoryPillView: View {
    let category: CommandPaletteSearchCategory
    @ObservedObject var viewModel: CommandPaletteViewModel
    var paletteGlass: Namespace.ID

    var body: some View {
        let isSelected = viewModel.searchCategoryFilter == category
        Button {
            viewModel.selectCategory(category)
        } label: {
            Text(category.segmentLabel)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, SpotiglassDesign.spacingM)
                .padding(.vertical, SpotiglassDesign.spacingS)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(SpotiglassDesign.controlAccent)
            }
        }
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .glassEffectID("palette.category.\(category.rawValue)", in: paletteGlass)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(category.segmentLabel)
    }
}
