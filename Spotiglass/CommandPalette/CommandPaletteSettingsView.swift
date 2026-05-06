import SwiftUI

struct CommandPaletteSettingsView: View {
    enum Presentation {
        /// Full Settings window or standalone sheet (large title, fixed minimum size).
        case standalone
        /// Embedded in the tabbed Settings window (no large title; fills the pane).
        case settingsTabs
    }

    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    @ObservedObject var commandPaletteManager: CommandPaletteManager
    var presentation: Presentation = .standalone

    @State private var pendingConflictByCommand: [String: PendingHotkeyConflict] = [:]

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                content
                    .padding(SpotiglassDesign.spacingL)
                    .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
            case .settingsTabs:
                content
                    .padding(SpotiglassDesign.spacingL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onDisappear {
            commandPaletteManager.isRecordingHotkey = false
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                if presentation == .standalone {
                    Text("Command Palette Keymap")
                        .font(.title2.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                    Text("Appearance")
                        .font(presentation == .settingsTabs ? .headline : .title3.weight(.semibold))
                    Toggle("Blur window behind palette", isOn: backdropBlurBinding)
                        .toggleStyle(.switch)
                    Text("When on, the rest of the window is slightly blurred while the palette is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Shortcuts")
                    .font(presentation == .settingsTabs ? .headline : .title3.weight(.semibold))

                Text("Click a field and press a shortcut. Esc cancels; Delete clears. Conflicts can replace the other binding.")
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
                    Button("Reset to Defaults") {
                        pendingConflictByCommand = [:]
                        keymapStore.resetToDefaults()
                    }
                }

                Divider()
                    .padding(.vertical, SpotiglassDesign.spacingXS)

                DisclosureGroup("Advanced (JSON)") {
                    advancedJSONSection
                }
                .tint(SpotiglassDesign.controlAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var backdropBlurBinding: Binding<Bool> {
        Binding(
            get: { keymapStore.settingsStore.settings.commandPalette.backdropBlur },
            set: { newValue in
                try? keymapStore.settingsStore.mutate { $0.commandPalette.backdropBlur = newValue }
            }
        )
    }

    private func keybindingRow(spec: CommandPaletteCommandSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
                Image(systemName: spec.iconSystemName)
                    .font(.system(size: 18, weight: .medium))
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

                HStack(spacing: SpotiglassDesign.spacingXS) {
                    HotkeyRecorderField(
                        commandID: spec.commandID,
                        keymapStore: keymapStore,
                        onRecordingChange: { active in
                            commandPaletteManager.isRecordingHotkey = active
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
                    .fixedSize(horizontal: true, vertical: false)

                    if keymapStore.primaryShortcut(for: spec.commandID) != nil {
                        Button {
                            pendingConflictByCommand[spec.commandID] = nil
                            do {
                                try keymapStore.clearBinding(commandID: spec.commandID)
                            } catch {
                                keymapStore.lastError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear shortcut")
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .animation(
                    .spring(response: 0.3, dampingFraction: 0.82),
                    value: keymapStore.primaryShortcut(for: spec.commandID) != nil
                )
            }

            if let pending = pendingConflictByCommand[spec.commandID] {
                HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                    (Text("Already assigned to ") + Text(displayTitle(for: pending.otherCommandID)).bold()
                        + Text(" — use Replace to move it here."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Replace") {
                        do {
                            try keymapStore.setBinding(
                                commandID: spec.commandID,
                                shortcut: pending.shortcut,
                                replaceConflicting: true
                            )
                            pendingConflictByCommand[spec.commandID] = nil
                        } catch {
                            keymapStore.lastError = error.localizedDescription
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
            Text("File: \(keymapStore.fileURL.path)")
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

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button("Apply") {
                    keymapStore.applyEditorText()
                }
                Button("Revert") {
                    pendingConflictByCommand = [:]
                    keymapStore.reloadFromDisk()
                }
                Button("Reset Defaults") {
                    pendingConflictByCommand = [:]
                    keymapStore.resetToDefaults()
                }
                Button("Open settings.json") {
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
