import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @FocusState private var isFocused: Bool
    @State private var previousResponder: NSResponder?
    @State private var previousWindow: NSWindow?

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
                        .focused($isFocused)
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
                HStack {
                    Text("↑↓ navigate")
                    Text("↩ run")
                    Text("esc close")
                    Spacer()
                    Text(scopeHintText)
                        .foregroundStyle(.secondary)
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
            isFocused = true
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

    private func sectionedList(sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]) -> some View {
        let flat = sections.flatMap(\.items)
        return List {
            ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, sectionEntry in
                Section {
                    ForEach(Array(sectionEntry.items.enumerated()), id: \.element.id) { _, item in
                        let flatIndex = flat.firstIndex(where: { $0.id == item.id }) ?? 0
                        paletteRow(item: item, isSelected: flatIndex == viewModel.selectedIndex)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(flatIndex == viewModel.selectedIndex ? Color.primary.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedIndex = flatIndex
                                Task { await viewModel.executeSelection() }
                            }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(sectionEntry.section.displayLabel)
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
    }

    private func paletteRow(item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: item.iconSystemName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
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

    private var scopeIconName: String {
        switch viewModel.currentScope {
        case .songs: "magnifyingglass"
        case .artists: "person.wave.2"
        case .commands: "command"
        }
    }

    private var scopeIconColor: Color {
        switch viewModel.currentScope {
        case .songs: .secondary
        case .artists: .green
        case .commands: .accentColor
        }
    }

    private var searchPlaceholder: String {
        switch viewModel.currentScope {
        case .songs: "Search songs"
        case .artists: "Filter by artist"
        case .commands: "Run a command"
        }
    }

    private var scopeHintText: String {
        switch viewModel.currentScope {
        case .songs: "type > for commands, @ for artists"
        case .artists: "@ artist scope"
        case .commands: "> command scope"
        }
    }
}
