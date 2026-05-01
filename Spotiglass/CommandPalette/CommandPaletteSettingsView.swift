import SwiftUI

struct CommandPaletteSettingsView: View {
    @ObservedObject var keymapStore: CommandPaletteKeymapStore

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
            Text("Command Palette Keymap")
                .font(.title2.weight(.semibold))

            Text("Edit a JSON keymap similar to Zed-style bindings. Changes apply immediately after validation.")
                .foregroundStyle(.secondary)

            Text("File: \(keymapStore.fileURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextEditor(text: $keymapStore.editorText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
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
                    keymapStore.reloadFromDisk()
                }
                Button("Reset Defaults") {
                    keymapStore.resetToDefaults()
                }
                Button("Open Keymap File") {
                    keymapStore.openKeymapFile()
                }
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
    }
}
