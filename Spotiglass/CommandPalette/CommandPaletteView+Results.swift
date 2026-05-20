import SwiftUI

// MARK: - Results card + body

struct CommandPaletteResultsCardView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let accessibilityReduceMotion: Bool
    var paletteGlass: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            if let progress = viewModel.prefetchProgress {
                CommandPalettePrefetchProgressHeader(progress: progress) { [weak viewModel] in
                    viewModel?.cancelPrefetchAllPlaylists?()
                }
            }
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

/// Slim header row shown above palette results while a "Load all your songs into
/// Spotiglass" prefetch is in flight (or briefly after it finishes).
struct CommandPalettePrefetchProgressHeader: View {
    let progress: PrefetchAllPlaylistsProgress
    /// Invoked when the user clicks the cancel chip. The host wires this to
    /// the same `playlists.prefetchAll` toggle so the second invocation cancels.
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: progress.phase == .running ? "square.and.arrow.down.on.square" : "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if progress.phase == .running, progress.total > 0 {
                ProgressView(value: Double(progress.completed + progress.skipped + progress.failed),
                             total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }
            Spacer(minLength: 0)
            if progress.phase == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(SpotiglassL10n.string("palette.settings.cancelPrefetchHelp"))
                .accessibilityLabel(SpotiglassL10n.string("palette.cancelPrefetch"))
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        let processed = progress.completed + progress.skipped + progress.failed
        switch progress.phase {
        case .running:
            if progress.total == 0 { return SpotiglassL10n.string("palette.prefetch.preparing") }
            return String(
                format: SpotiglassL10n.string("palette.prefetch.loading"),
                processed,
                progress.total
            )
        case .finished:
            if progress.failed == 0 {
                return String(
                    format: SpotiglassL10n.string("palette.prefetch.loadedAll"),
                    progress.completed + progress.skipped
                )
            }
            return String(
                format: SpotiglassL10n.string("palette.prefetch.loadedPartial"),
                progress.completed + progress.skipped,
                progress.total,
                progress.failed
            )
        case .cancelled:
            return String(
                format: SpotiglassL10n.string("palette.prefetch.cancelled"),
                processed,
                progress.total
            )
        }
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
                    Text(String(format: SpotiglassL10n.string("palette.noResults"), trimmed))
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
                        .accessibilityLabel(SpotiglassL10n.string("palette.searching"))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                        .accessibilityLabel(SpotiglassL10n.string("palette.searching"))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }
}
