import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore

    private enum SearchFocusField {
        case query
    }

    @FocusState private var focusedField: SearchFocusField?
    @State private var previousResponder: NSResponder?
    @State private var previousWindow: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Namespace private var paletteGlass

    /// Full-strength `Material` reads heavy; partial opacity keeps the frosted hint while leaving more detail visible behind the palette.
    private static let backdropMaterialOpacity: CGFloat = 0.55

    @ViewBuilder
    private var paletteBackdrop: some View {
        Group {
            if settingsStore.settings.commandPalette.backdropBlur {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(Self.backdropMaterialOpacity)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture { viewModel.hide() }
        .accessibilityHidden(true)
    }

    var body: some View {
        ZStack {
            paletteBackdrop

            GlassEffectContainer(spacing: SpotiglassDesign.spacingS) {
                VStack(spacing: SpotiglassDesign.spacingS) {
                    searchCard
                    if shouldShowResultsCard {
                        resultsCard
                    }
                    footerRow
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(SpotiglassDesign.spacingXL)
                .animation(
                    accessibilityReduceMotion ? nil : .smooth(duration: 0.30),
                    value: shouldShowResultsCard
                )
            }
        }
        .onAppear {
            previousWindow = NSApp.keyWindow
            previousResponder = NSApp.keyWindow?.firstResponder
            viewModel.restoreFocus = { [weakWindow = previousWindow, weakResponder = previousResponder] in
                if let window = weakWindow, let responder = weakResponder {
                    window.makeFirstResponder(responder)
                }
            }
            scheduleSearchFieldFocus()
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
            if !isLoading {
                scheduleSearchFieldFocus()
            }
        }
    }

    /// SwiftUI on macOS often ignores immediate `@FocusState` updates in `onAppear`; deferring fixes typing-at-open.
    private func scheduleSearchFieldFocus() {
        DispatchQueue.main.async {
            focusedField = .query
            DispatchQueue.main.async {
                focusedField = .query
            }
        }
    }

    /// Hides the results panel while the palette is "idle" (empty query or only a scope prefix) so the footer chips
    /// sit directly under the search field. Loading and error states still surface so user feedback is never dropped.
    private var shouldShowResultsCard: Bool {
        let trimmed = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let onlyPrefix = trimmed == ">" || trimmed == "@"
        if trimmed.isEmpty || onlyPrefix {
            return viewModel.isLoading || viewModel.errorText != nil
        }
        let parsed = CommandPaletteScope.parse(viewModel.query)
        let stripped = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsed.scope == .songs,
           !stripped.isEmpty,
           stripped.count < CommandPaletteViewModel.minimumPaletteSearchQueryCharacters {
            return viewModel.isLoading || viewModel.errorText != nil
        }
        return true
    }

    private var searchCard: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: scopeIconName)
                .foregroundStyle(scopeIconColor)
            TextField(searchPlaceholder, text: $viewModel.query)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focusedField, equals: .query)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.queryDidChangeFromTextField()
                }
                .onSubmit {
                    Task { await viewModel.executeSelection() }
                }
        }
        .padding(SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous))
        .glassEffectID("palette.search", in: paletteGlass)
    }

    private var resultsCard: some View {
        VStack(spacing: 0) {
            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SpotiglassDesign.spacingM)
                    .padding(.top, SpotiglassDesign.spacingS)
            }

            resultsBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous))
        .glassEffectID("palette.results", in: paletteGlass)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            hintsChip
            Spacer(minLength: 8)
            if viewModel.currentScope == .commands {
                commandsHintChip
            } else {
                categoryPillsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hintsChip: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text("↑↓ navigate")
            Text("↩ run")
            Text("esc close")
            if viewModel.canEnqueueSelectedItem {
                Text("⇧↩ queue")
            }
            if viewModel.canPinSelectedItem {
                Text("⌘↩ pin")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .glassEffectID("palette.hints", in: paletteGlass)
    }

    private var commandsHintChip: some View {
        Text("Remove \(Text(">").foregroundStyle(.tertiary)) prefix to search Spotify")
            .multilineTextAlignment(.trailing)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingS)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .glassEffectID("palette.footerTrailing", in: paletteGlass)
    }

    private var categoryPillsRow: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            ForEach(viewModel.availableSearchCategories, id: \.self) { category in
                categoryPill(category: category)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search result category")
    }

    @ViewBuilder
    private func categoryPill(category: CommandPaletteSearchCategory) -> some View {
        let isSelected = viewModel.searchCategoryFilter == category
        Button {
            viewModel.searchCategoryFilter = category
            viewModel.refresh()
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

    private var searchingPlaceholder: some View {
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

    @ViewBuilder
    private var resultsBody: some View {
        let sections = viewModel.sections
        let trimmed = viewModel.strippedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEmpty = sections.allSatisfy { $0.items.isEmpty }
        let hasUserQuery = !viewModel.query.isEmpty
        let onlyPrefix = (viewModel.query == ">" || viewModel.query == "@")

        if viewModel.isLoading && allEmpty {
            searchingPlaceholder
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
            sectionedList(sections: sections)
        }
    }

    /// Stable ids for ``ScrollViewReader`` / `scrollTo`; aligned with ``CommandPaletteViewModel/selectedIndex`` (flat ``visibleItems`` order).
    private func paletteRowScrollID(_ flatIndex: Int) -> String {
        "palette-result-\(flatIndex)"
    }

    /// When results reload but `selectedIndex` stays `0`, `onChange(of: selectedIndex)` does not fire — use this signature to scroll the first row back into view.
    private var paletteResultsScrollSignature: String {
        viewModel.visibleItems.map(\.id).joined(separator: "\u{1e}")
    }

    private func sectionedList(sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]) -> some View {
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

        return ScrollViewReader { proxy in
            List {
                ForEach(Array(sectionChunks.enumerated()), id: \.offset) { sectionIndex, chunk in
                    Section {
                        ForEach(chunk.rows, id: \.flatIndex) { row in
                            paletteRow(item: row.item, isSelected: row.flatIndex == viewModel.selectedIndex)
                                .id(paletteRowScrollID(row.flatIndex))
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

    private func scrollPaletteSelectionToIndex(proxy: ScrollViewProxy, index: Int) {
        guard viewModel.visibleItems.indices.contains(index) else { return }
        let id = paletteRowScrollID(index)
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

    private func paletteRow(item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            paletteRowLeading(item: item)
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

    @ViewBuilder
    private func paletteRowLeading(item: CommandPaletteItem) -> some View {
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

    private var scopeIconName: String {
        switch viewModel.currentScope {
        case .commands:
            "command"
            case .songs:
            switch viewModel.searchCategoryFilter {
            case .all: "magnifyingglass"
            case .tracks: "music.note"
            case .artists: "person.wave.2"
            case .thisPlaylist: "music.note.list"
            case .myPlaylists: "books.vertical"
            }
        }
    }

    private var scopeIconColor: Color {
        switch viewModel.currentScope {
        case .commands:
            .accentColor
            case .songs:
            switch viewModel.searchCategoryFilter {
            case .all: .secondary
            case .tracks: .secondary
            case .artists: .secondary
            case .thisPlaylist: .secondary
            case .myPlaylists: .secondary
            }
        }
    }

    private var searchPlaceholder: String {
        switch viewModel.currentScope {
        case .commands:
            "Run a command"
            case .songs:
            switch viewModel.searchCategoryFilter {
            case .all:
                "Search Spotify"
            case .tracks:
                "Search tracks"
            case .artists:
                "Search artists"
            case .thisPlaylist:
                "Search in this playlist"
            case .myPlaylists:
                "Search your playlists"
            }
        }
    }
}

private struct CommandPaletteArtistAvatar: View {
    let imageURL: URL?
    let fallbackSystemName: String
    private let diameter: CGFloat = 28

    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .task(id: imageURL?.absoluteString ?? "") {
            guard let imageURL else {
                loadedImage = nil
                return
            }
            loadedImage = await ArtworkImageStore.shared.image(for: imageURL)
        }
    }
}

/// Square album-cover thumbnail for `.tracks` and `.thisPlaylist` palette rows.
/// Resolves through `ArtworkImageStore`, which serves from memory/disk before
/// falling back to a single network fetch on a cold cache.
private struct CommandPaletteTrackArtwork: View {
    let imageURL: URL
    let fallbackSystemName: String
    private let side: CGFloat = 28

    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .task(id: imageURL.absoluteString) {
            loadedImage = await ArtworkImageStore.shared.image(for: imageURL)
        }
    }
}
