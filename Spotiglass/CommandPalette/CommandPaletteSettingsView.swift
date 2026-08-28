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
    /// Command whose field is currently recording, so the "Esc cancels / Delete
    /// clears" hint can be shown inline on the active row instead of only at the top.
    @State private var recordingCommandID: String?

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                ScrollView {
                    content
                }
                .padding(SpotiglassDesign.spacingL)
                .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
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
            recordingCommandID = nil
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
            if presentation == .standalone {
                Text(SpotiglassL10n.string("palette.settings.title"))
                    .font(.title2.weight(.semibold))
            }

            Text(SpotiglassL10n.string("palette.settings.shortcuts"))
                .font(presentation == .settingsTabs ? .headline : .title3.weight(.semibold))

            Text(SpotiglassL10n.string("palette.settings.hint"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                ForEach(CommandPaletteCommandCatalog.editable) { spec in
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
                value: CommandPaletteCommandCatalog.editable.map(\.commandID)
            )

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button(SpotiglassL10n.string("palette.settings.reset")) {
                    pendingConflictByCommand = [:]
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
                Image(systemName: spec.iconSystemName)
                    .font(SpotiglassDesign.Typography.commandPaletteIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.title)
                        .font(.subheadline.weight(.semibold))
                    Text(spec.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if spec.isDestructive {
                    // Destructive commands can't be bound to a single keypress; they
                    // run from the Command Palette only, where intent is explicit.
                    Label(
                        SpotiglassL10n.string("palette.settings.notBindable"),
                        systemImage: "lock.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(SpotiglassL10n.string("palette.settings.notBindable.hint"))
                } else {
                    HStack(spacing: SpotiglassDesign.spacingXS) {
                        HotkeyRecorderField(
                            commandID: spec.commandID,
                            keymapStore: keymapStore,
                            onRecordingChange: { active in
                                onRecordingChange(active)
                                recordingCommandID = active ? spec.commandID : nil
                                if active {
                                    pendingConflictByCommand[spec.commandID] = nil
                                }
                            },
                            onCaptureConflict: { shortcut, otherID in
                                pendingConflictByCommand[spec.commandID] = PendingHotkeyConflict(
                                    shortcut: shortcut,
                                    otherCommandID: otherID
                                )
                            },
                            onApplied: {
                                pendingConflictByCommand[spec.commandID] = nil
                            }
                        )
                        // Consistent field width so assigned (chip) and unassigned
                        // ("Click to record") states read as one control, not two.
                        .frame(minWidth: 132, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)

                        if keymapStore.primaryShortcut(for: spec.commandID) != nil {
                            Button {
                                pendingConflictByCommand[spec.commandID] = nil
                                do {
                                    try keymapStore.clearBinding(commandID: spec.commandID)
                                } catch {
                                    keymapStore.lastError = CommandPaletteKeymapErrorPresenter.message(
                                        for: error,
                                        source: keymapStore.fileURL.path,
                                        operation: "clear shortcut"
                                    )
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(SpotiglassDesign.Typography.commandPaletteClearShortcut)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(SpotiglassL10n.string("palette.settings.clearShortcut"))
                            .accessibilityLabel(SpotiglassL10n.string("a11y.palette.clearShortcut"))
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        }
                    }
                    .animation(
                        .spring(response: 0.3, dampingFraction: 0.82),
                        value: keymapStore.primaryShortcut(for: spec.commandID) != nil
                    )
                }
            }

            if recordingCommandID == spec.commandID {
                Text(SpotiglassL10n.string("palette.settings.recordingHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28 + SpotiglassDesign.spacingM)
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
                .padding(.leading, 28 + SpotiglassDesign.spacingM)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .padding(.vertical, 4)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.86),
            value: pendingConflictByCommand[spec.commandID] != nil
        )
    }

    private func displayTitle(for commandID: String) -> String {
        CommandPaletteCommandCatalog.editable.first { $0.commandID == commandID }?.title ?? commandID
    }

    private var advancedJSONSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(String(format: SpotiglassL10n.string("palette.settings.file"), keymapStore.fileURL.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextEditor(text: $keymapStore.editorText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .padding(6)
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
                    keymapStore.reloadFromDisk()
                }
                Button(SpotiglassL10n.string("palette.settings.resetDefaults")) {
                    pendingConflictByCommand = [:]
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
