import SwiftUI

// MARK: - Results card + body

struct CommandPaletteResultsCardView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let accessibilityReduceMotion: Bool
    var paletteGlass: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SpotiglassDesign.spacingM)
                    .padding(.top, SpotiglassDesign.spacingS)
            }

            CommandPaletteResultsBodyView(
                viewModel: viewModel,
                accessibilityReduceMotion: accessibilityReduceMotion
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous))
        .glassEffectID("palette.results", in: paletteGlass)
    }
}

struct CommandPaletteResultsBodyView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let accessibilityReduceMotion: Bool

    var body: some View {
        let sections = viewModel.sections
        let trimmed = viewModel.strippedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEmpty = sections.allSatisfy { $0.items.isEmpty }
        let hasUserQuery = !viewModel.query.isEmpty
        let onlyPrefix = (viewModel.query == ">" || viewModel.query == "@")

        if viewModel.isLoading && allEmpty {
            CommandPaletteSearchingPlaceholderView(accessibilityReduceMotion: accessibilityReduceMotion)
        } else if sections.isEmpty || allEmpty {
            if hasUserQuery, !onlyPrefix, !trimmed.isEmpty, !viewModel.isLoading {
                VStack {
                    Spacer()
                    Text("No results for \"\(trimmed)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
            } else {
                Spacer()
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
            }
        } else {
            CommandPaletteSectionedListView(
                viewModel: viewModel,
                sections: sections,
                accessibilityReduceMotion: accessibilityReduceMotion
            )
        }
    }
}

struct CommandPaletteSearchingPlaceholderView: View {
    let accessibilityReduceMotion: Bool

    var body: some View {
        VStack {
            Spacer()
            Group {
                if accessibilityReduceMotion {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityLabel("Searching Spotify")
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                        .accessibilityLabel("Searching Spotify")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }
}
