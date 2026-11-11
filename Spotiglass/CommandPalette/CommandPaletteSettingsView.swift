import AppKit
import SwiftUI

struct CommandPaletteSettingsView: View {
    enum Presentation {
        /// Full Settings window or standalone sheet (large title, fixed minimum size).
        case standalone
        /// Embedded in the tabbed Settings window (no large title; fills the pane).
        case settingsTabs
    }

    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    var presentation: Presentation = .standalone
    /// Settings has no palette of its own now that palette state is scene-owned,
    /// so it reports recording state outwards and the scene registry suspends
    /// every live main-window key monitor for the duration.
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var pendingConflictByCommand: [String: PendingHotkeyConflict] = [:]
    /// A failed capture still ends recording, but keeps its localized reason on
    /// the row so an unsupported key or a menu-owned chord is never silent.
    @State private var captureErrorByCommand: [String: String] = [:]
    /// Typed into the field over the list, so a command is found by name
    /// instead of by scrolling (#541).
    @State private var searchText = ""

    /// Commands the list shows for a search: every bindable command whose title
    /// or subtitle contains the text, ignoring case and accents.
    static func commands(matching query: String) -> [CommandPaletteCommandSpec] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CommandPaletteCommandCatalog.bindable }
        return CommandPaletteCommandCatalog.bindable.filter {
            $0.title.localizedStandardContains(query) || $0.subtitle.localizedStandardContains(query)
        }
    }

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                ScrollView {
                    content
                }
                .padding(SpotiglassDesign.spacingL)
                .frame(minWidth: SpotiglassDesign.Layout.standaloneSettingsMinWidth, minHeight: SpotiglassDesign.Layout.standaloneSettingsMinHeight, alignment: .topLeading)
            case .settingsTabs:
                // Grouped Form to match the other settings panes. It also supplies
                // this pane's scrolling: the settings shell deliberately has no
                // ScrollView of its own, so a plain stack here would overflow the
                // window and slide under the titlebar.
                Form {
                    Section {
                        content
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onDisappear {
            onRecordingChange(false)
            captureErrorByCommand = [:]
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
            if presentation == .standalone {
                Text(SpotiglassL10n.string("palette.settings.title"))
                    .font(.title2.weight(.semibold))
            }

            // No instruction line: each field says what to do itself (#541).
            CommandSearchField(
                text: $searchText,
                prompt: SpotiglassL10n.string("palette.settings.search.placeholder")
            )

            let visible = Self.commands(matching: searchText)
            if visible.isEmpty {
                Text(SpotiglassL10n.format("palette.settings.search.noResults", searchText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, SpotiglassDesign.spacingL)
            }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                ForEach(visible) { spec in
                    keybindingRow(spec: spec)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            )
                        )
                }
            }
            .animation(
                .spring(response: 0.34, dampingFraction: 0.86),
                // Keyed on the catalog, not the search: rows filter instantly
                // as you type, the way every search list on the Mac does.
                value: CommandPaletteCommandCatalog.bindable.map(\.commandID)
            )

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button(SpotiglassL10n.string("palette.settings.reset")) {
                    pendingConflictByCommand = [:]
                    captureErrorByCommand = [:]
                    keymapStore.resetToDefaults()
                }
            }

            Divider()
                .padding(.vertical, SpotiglassDesign.spacingXS)

            DisclosureGroup(SpotiglassL10n.string("palette.settings.advanced")) {
                advancedJSONSection
            }
            .tint(SpotiglassDesign.controlAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keybindingRow(spec: CommandPaletteCommandSpec) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXXS) {
            HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
                Image(systemName: spec.iconSystemName)
                    .font(SpotiglassDesign.Typography.commandPaletteIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: SpotiglassDesign.Layout.iconButtonSize, alignment: .center)

                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingHalf) {
                    Text(spec.title)
                        .font(.subheadline.weight(.semibold))
                    Text(spec.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // One shortcut column for every row: a field of one width, with
                // its clear control inside, whether the command is bound or not,
                // so the trailing edge never moves (#428).
                shortcutField(spec: spec)
                    .frame(width: SpotiglassDesign.Layout.shortcutFieldWidth)
            }

            if let captureError = captureErrorByCommand[spec.commandID] {
                Label(captureError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SpotiglassDesign.Layout.iconButtonSize + SpotiglassDesign.spacingM)
                    .transition(.opacity)
            }

            if let pending = pendingConflictByCommand[spec.commandID] {
                HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                    Text(
                        String(
                            format: SpotiglassL10n.string("palette.settings.conflict"),
                            displayTitle(for: pending.otherCommandID)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(SpotiglassL10n.string("palette.settings.replace")) {
                        do {
                            try keymapStore.setBinding(
                                commandID: spec.commandID,
                                shortcut: pending.shortcut,
                                replaceConflicting: true
                            )
                            pendingConflictByCommand[spec.commandID] = nil
                        } catch {
                            keymapStore.lastError = CommandPaletteKeymapErrorPresenter.message(
                                for: error,
                                source: keymapStore.fileURL.path,
                                operation: "replace shortcut"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.leading, SpotiglassDesign.Layout.iconButtonSize + SpotiglassDesign.spacingM)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }

            ForEach(crossContextUsages(for: spec)) { usage in
                Label(
                    usageNote(for: usage),
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SpotiglassDesign.Layout.iconButtonSize + SpotiglassDesign.spacingM)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXXS)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.86),
            value: pendingConflictByCommand[spec.commandID] != nil
        )
    }

    private func shortcutField(spec: CommandPaletteCommandSpec) -> some View {
        HotkeyRecorderField(
            commandID: spec.commandID,
            keymapStore: keymapStore,
            onRecordingChange: { active in
                onRecordingChange(active)
                if active {
                    pendingConflictByCommand[spec.commandID] = nil
                }
                // A reason shown while recording belongs to that attempt.
                captureErrorByCommand[spec.commandID] = nil
            },
            onCaptureConflict: { shortcut, otherID in
                captureErrorByCommand[spec.commandID] = nil
                pendingConflictByCommand[spec.commandID] = PendingHotkeyConflict(
                    shortcut: shortcut,
                    otherCommandID: otherID
                )
            },
            onCaptureFailure: { message in
                pendingConflictByCommand[spec.commandID] = nil
                captureErrorByCommand[spec.commandID] = message
            },
            onApplied: {
                pendingConflictByCommand[spec.commandID] = nil
                captureErrorByCommand[spec.commandID] = nil
            },
            conflictingShortcut: pendingConflictByCommand[spec.commandID]?.shortcut,
            showsProblem: pendingConflictByCommand[spec.commandID] != nil
                || captureErrorByCommand[spec.commandID] != nil
        )
    }

    private func displayTitle(for commandID: String) -> String {
        CommandPaletteCommandCatalog.editable.first { $0.commandID == commandID }?.title ?? commandID
    }

    private func crossContextUsages(for spec: CommandPaletteCommandSpec) -> [CommandPaletteShortcutUsage] {
        guard let shortcut = keymapStore.primaryShortcut(for: spec.commandID) else { return [] }
        return keymapStore.crossContextUsages(
            of: shortcut,
            excludingCommand: spec.commandID,
            proposedWhen: spec.defaultWhen
        )
    }

    private func usageNote(for usage: CommandPaletteShortcutUsage) -> String {
        SpotiglassL10n.format(
            "palette.settings.alsoUsed",
            displayTitle(for: usage.commandID),
            contextDescription(for: usage.context)
        )
    }

    private func contextDescription(for context: CommandPaletteContext) -> String {
        switch context {
        case .always:
            SpotiglassL10n.string("palette.settings.context.always")
        case .signedIn:
            SpotiglassL10n.string("palette.settings.context.signedIn")
        case .signedOut:
            SpotiglassL10n.string("palette.settings.context.signedOut")
        case .paletteOpen:
            SpotiglassL10n.string("palette.settings.context.paletteOpen")
        }
    }

    private var advancedJSONSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(String(format: SpotiglassL10n.string("palette.settings.file"), keymapStore.fileURL.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextEditor(text: $keymapStore.editorText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: SpotiglassDesign.Layout.textEditorMinHeight)
                .padding(SpotiglassDesign.spacingXS)
                .background(.background, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

            if let lastError = keymapStore.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // The GUI shortcut controls above apply live; this JSON editor does not,
            // so make the Apply/Revert scope explicit to avoid the ambiguity in #29.
            Text(SpotiglassL10n.string("palette.settings.advanced.applyHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button(SpotiglassL10n.string("palette.settings.apply")) {
                    keymapStore.applyEditorText()
                }
                Button(SpotiglassL10n.string("palette.settings.revert")) {
                    pendingConflictByCommand = [:]
                    captureErrorByCommand = [:]
                    keymapStore.reloadFromDisk()
                }
                Button(SpotiglassL10n.string("palette.settings.resetDefaults")) {
                    pendingConflictByCommand = [:]
                    captureErrorByCommand = [:]
                    keymapStore.resetToDefaults()
                }
                Button(SpotiglassL10n.string("palette.settings.openJSON")) {
                    keymapStore.openKeymapFile()
                }
            }
        }
        .padding(.top, SpotiglassDesign.spacingXS)
    }
}

private struct PendingHotkeyConflict: Equatable {
    let shortcut: CommandShortcut
    let otherCommandID: String
}

/// The search field over the shortcut list. AppKit's own, so it looks, clears
/// and handles Esc like every other search field on the Mac.
private struct CommandSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
