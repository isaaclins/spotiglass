import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel

    private enum SearchFocusField {
        case query
    }

    @FocusState private var focusedField: SearchFocusField?
    @State private var previousResponder: NSResponder?
    @State private var previousWindow: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.hide()
                }

            VStack(spacing: 0) {
                HStack(spacing: SpotiglassDesign.spacingS) {
                    Image(systemName: scopeIconName)
                        .foregroundStyle(scopeIconColor)
                    TextField(searchPlaceholder, text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .query)
                        .onChange(of: viewModel.query) { _, _ in
                            viewModel.refresh()
                        }
                        .onSubmit {
                            Task { await viewModel.executeSelection() }
                        }
                }
                .padding(SpotiglassDesign.spacingM)

                Divider()

                if viewModel.isLoading {
                    ProgressView("Searching Spotify...")
                        .padding(SpotiglassDesign.spacingM)
                }

                if let errorText = viewModel.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, SpotiglassDesign.spacingM)
                        .padding(.top, SpotiglassDesign.spacingS)
                }

                resultsBody

                Divider()
                HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
                    HStack(spacing: SpotiglassDesign.spacingS) {
                        Text("↑↓ navigate")
                        Text("↩ run")
                        Text("esc close")
                        if viewModel.currentScope != .commands {
                            Text("Tab filter")
                        }
                        if viewModel.canPinSelectedItem {
                            Text("⌘↩ pin")
                        }
                    }
                    Spacer(minLength: 8)
                    footerTrailing
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(SpotiglassDesign.spacingS)
            }
            .frame(maxWidth: 760)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 24, y: 14)
            .padding(SpotiglassDesign.spacingXL)
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

    @ViewBuilder
    private var footerTrailing: some View {
        if viewModel.currentScope == .commands {
            Text("Remove \(Text(">").foregroundStyle(.tertiary)) prefix to search Spotify")
                .multilineTextAlignment(.trailing)
        } else {
            Picker("Result category", selection: Binding(
                get: { viewModel.searchCategoryFilter },
                set: { newValue in
                    viewModel.searchCategoryFilter = newValue
                    viewModel.refresh()
                }
            )) {
                ForEach(viewModel.availableSearchCategories, id: \.self) { category in
                    Text(category.segmentLabel).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
            .accessibilityLabel("Search result category")
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        let sections = viewModel.sections
        let trimmed = viewModel.strippedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEmpty = sections.allSatisfy { $0.items.isEmpty }
        let hasUserQuery = !viewModel.query.isEmpty
        let onlyPrefix = (viewModel.query == ">" || viewModel.query == "@")

        if sections.isEmpty || allEmpty {
            if hasUserQuery, !onlyPrefix, !trimmed.isEmpty, !viewModel.isLoading {
                VStack {
                    Spacer()
                    Text("No results for \"\(trimmed)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
                .frame(height: 360)
            } else {
                Spacer().frame(height: 360)
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
                Text(item.title)
                    .lineLimit(1)
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
            case .artists: .green
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
