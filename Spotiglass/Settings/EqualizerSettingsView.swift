import SwiftUI

/// Settings → Equalizer pane: enable toggle, preset picker (built-ins + user-saved),
/// preamp slider, ten vertical band sliders. Mutations write through the shared
/// ``SpotiglassSettingsStore`` and are forwarded live to ``AudioEqualizerEngine``.
struct EqualizerSettingsView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore
    @ObservedObject var engine: AudioEqualizerEngine

    @State private var pendingSavePresetName: String = ""
    @State private var isPresentingSaveSheet: Bool = false
    @State private var saveSheetError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                statusRow
                forwardingTargetRow
                presetRow
                preampRow
                bandsRow
                footerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpotiglassDesign.spacingL)
        }
        .sheet(isPresented: $isPresentingSaveSheet) {
            SavePresetSheet(
                name: $pendingSavePresetName,
                error: $saveSheetError,
                onCancel: {
                    isPresentingSaveSheet = false
                    pendingSavePresetName = ""
                    saveSheetError = nil
                },
                onSave: { name in
                    do {
                        try saveCurrentAsPreset(named: name)
                        isPresentingSaveSheet = false
                        pendingSavePresetName = ""
                        saveSheetError = nil
                    } catch {
                        saveSheetError = error.localizedDescription
                    }
                }
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.eq.title"))
                .font(.title3.weight(.semibold))
            Text(SpotiglassL10n.string("settings.eq.description"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        let equalizer = settingsStore.settings.equalizer
        return HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
            Toggle(SpotiglassL10n.string("settings.eq.enableToggle"), isOn: equalizerEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.large)

            if let lastError = engine.lastError, !lastError.isEmpty {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if equalizer.enabled, !engine.isRunning {
                Label(SpotiglassL10n.string("settings.eq.starting"), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if equalizer.enabled {
                Label(SpotiglassL10n.string("settings.eq.live"), systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    /// Picker for the hardware device the EQ should forward processed audio to.
    /// Refreshed on appear; the driver's background watcher (~500 ms) picks up
    /// the new UID and atomically swaps its `AudioDeviceIOProc` so the change
    /// is audible without toggling EQ off and on.
    private var forwardingTargetRow: some View {
        let equalizer = settingsStore.settings.equalizer
        let devices = engine.availableForwardingTargets()
        return HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("settings.eq.target.label"))
                .font(.subheadline.weight(.semibold))

            Picker(SpotiglassL10n.string("settings.eq.target.label"), selection: forwardingTargetBinding) {
                Text(SpotiglassL10n.string("settings.eq.target.auto")).tag(Optional<String>.none)
                ForEach(devices, id: \.id) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            if let active = activeForwardingDeviceName(equalizer: equalizer, devices: devices) {
                Label(active, systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeForwardingDeviceName(
        equalizer: EqualizerSettings,
        devices: [AudioDeviceEnumerator.Device]
    ) -> String? {
        guard let uid = equalizer.forwardingTargetUID
            ?? engine.currentForwardingTargetUID()
        else { return nil }
        return devices.first { $0.uid == uid }?.name ?? uid
    }

    private var forwardingTargetBinding: Binding<String?> {
        Binding(
            get: { settingsStore.settings.equalizer.forwardingTargetUID },
            set: { newValue in
                mutateEqualizer { $0.forwardingTargetUID = newValue }
                if let uid = newValue, !uid.isEmpty {
                    engine.setForwardingTarget(uid: uid)
                }
                // nil ("Auto") leaves the file alone — next enable() will
                // capture the current default and write a fresh fallback.
            }
        )
    }

    private var presetRow: some View {
        let equalizer = settingsStore.settings.equalizer
        return HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("settings.eq.preset.label"))
                .font(.subheadline.weight(.semibold))

            Picker(SpotiglassL10n.string("settings.eq.preset.label"), selection: presetBinding) {
                Section(SpotiglassL10n.string("settings.eq.preset.builtin")) {
                    ForEach(EqualizerPreset.builtIns) { preset in
                        Text(preset.name).tag(Optional(preset.name))
                    }
                }
                if !equalizer.userPresets.isEmpty {
                    Section(SpotiglassL10n.string("settings.eq.preset.saved")) {
                        ForEach(equalizer.userPresets) { preset in
                            Text(preset.name).tag(Optional(preset.name))
                        }
                    }
                }
                Text(SpotiglassL10n.string("settings.eq.preset.custom"))
                    .tag(Optional<String>.none)
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer()

            Button {
                pendingSavePresetName = ""
                saveSheetError = nil
                isPresentingSaveSheet = true
            } label: {
                Label(SpotiglassL10n.string("settings.eq.preset.save"), systemImage: "square.and.arrow.down")
            }

            Button(role: .destructive) {
                deleteActiveUserPreset()
            } label: {
                Label(SpotiglassL10n.string("settings.eq.preset.delete"), systemImage: "trash")
            }
            .disabled(!isActivePresetUserDefined)
        }
    }

    private var preampRow: some View {
        let equalizer = settingsStore.settings.equalizer
        return VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            HStack {
                Text(SpotiglassL10n.string("settings.eq.preamp"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatGain(equalizer.preamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: preampBinding,
                in: EqualizerSettings.preampRangeDB,
                step: 0.5
            ) {
                Text(SpotiglassL10n.string("settings.eq.preamp"))
            } minimumValueLabel: {
                Text("\(Int(EqualizerSettings.preampRangeDB.lowerBound)) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+\(Int(EqualizerSettings.preampRangeDB.upperBound)) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bandsRow: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("settings.eq.bands"))
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: SpotiglassDesign.spacingS) {
                ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                    EqualizerBandColumn(
                        frequencyHz: EqualizerSettings.bandFrequenciesHz[index],
                        gain: gainBinding(forBand: index)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerActions: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Button(SpotiglassL10n.string("settings.eq.reset")) {
                applyPreset(EqualizerPreset.flat)
            }

            Button(SpotiglassL10n.string("settings.eq.openSettings")) {
                settingsStore.openFileInDefaultEditor()
            }

            Spacer()

            if let storeError = settingsStore.lastError {
                Text(storeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Bindings

    private var equalizerEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.equalizer.enabled },
            set: { newValue in
                mutateEqualizer { $0.enabled = newValue }
                if newValue {
                    do {
                        try engine.start(
                            forwardingTargetUID: settingsStore.settings.equalizer.forwardingTargetUID
                        )
                        engine.apply(settings: settingsStore.settings.equalizer)
                    } catch {
                        // Revert toggle if engine could not start.
                        mutateEqualizer { $0.enabled = false }
                    }
                } else {
                    engine.stop()
                }
            }
        )
    }

    private var presetBinding: Binding<String?> {
        Binding(
            get: { settingsStore.settings.equalizer.activePresetName },
            set: { newValue in
                guard let name = newValue,
                      let preset = EqualizerPreset.find(named: name, userPresets: settingsStore.settings.equalizer.userPresets)
                else {
                    mutateEqualizer { $0.activePresetName = nil }
                    return
                }
                applyPreset(preset)
            }
        )
    }

    private var preampBinding: Binding<Double> {
        Binding(
            get: { settingsStore.settings.equalizer.preamp },
            set: { newValue in
                let clamped = EqualizerSettings.clampPreamp(newValue)
                mutateEqualizer { eq in
                    eq.preamp = clamped
                    if !eq.matches(EqualizerPreset.find(named: eq.activePresetName ?? "", userPresets: eq.userPresets) ?? EqualizerPreset.flat) {
                        eq.activePresetName = nil
                    }
                }
                engine.setPreamp(dB: Float(clamped))
            }
        )
    }

    private func gainBinding(forBand index: Int) -> Binding<Double> {
        Binding(
            get: { settingsStore.settings.equalizer.bands[index] },
            set: { newValue in
                let clamped = EqualizerSettings.clampGain(newValue)
                mutateEqualizer { eq in
                    eq.bands[index] = clamped
                    if let activeName = eq.activePresetName,
                       let activePreset = EqualizerPreset.find(named: activeName, userPresets: eq.userPresets),
                       !eq.matches(activePreset) {
                        eq.activePresetName = nil
                    }
                }
                engine.setBandGain(index, dB: Float(clamped))
            }
        )
    }

    // MARK: - Actions

    private func applyPreset(_ preset: EqualizerPreset) {
        mutateEqualizer { eq in
            eq.apply(preset: preset)
        }
        engine.apply(settings: settingsStore.settings.equalizer)
    }

    private func saveCurrentAsPreset(named rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SavePresetError.emptyName
        }
        if EqualizerPreset.builtIns.contains(where: { $0.name == name }) {
            throw SavePresetError.reservedName
        }
        let preset = EqualizerPreset(
            name: name,
            preamp: settingsStore.settings.equalizer.preamp,
            bands: settingsStore.settings.equalizer.bands
        )
        try settingsStore.mutate { file in
            file.equalizer.userPresets.removeAll { $0.name == name }
            file.equalizer.userPresets.append(preset)
            file.equalizer.userPresets.sort { $0.name.lowercased() < $1.name.lowercased() }
            file.equalizer.activePresetName = name
        }
    }

    private func deleteActiveUserPreset() {
        guard let name = settingsStore.settings.equalizer.activePresetName,
              settingsStore.settings.equalizer.userPresets.contains(where: { $0.name == name })
        else { return }
        try? settingsStore.mutate { file in
            file.equalizer.userPresets.removeAll { $0.name == name }
            file.equalizer.activePresetName = nil
        }
    }

    private var isActivePresetUserDefined: Bool {
        guard let name = settingsStore.settings.equalizer.activePresetName else { return false }
        return settingsStore.settings.equalizer.userPresets.contains { $0.name == name }
    }

    private func mutateEqualizer(_ change: (inout EqualizerSettings) -> Void) {
        do {
            try settingsStore.mutate { file in
                change(&file.equalizer)
                file.equalizer.bands = EqualizerSettings.normalizedBands(file.equalizer.bands)
                file.equalizer.preamp = EqualizerSettings.clampPreamp(file.equalizer.preamp)
            }
        } catch {
            settingsStore.lastError = error.localizedDescription
        }
    }

    private func formatGain(_ value: Double) -> String {
        let clamped = EqualizerSettings.clampGain(value)
        let prefix = clamped > 0 ? "+" : (clamped == 0 ? " " : "")
        return String(format: "%@%.1f dB", prefix, clamped)
    }
}

private enum SavePresetError: LocalizedError {
    case emptyName
    case reservedName

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Preset name cannot be empty."
        case .reservedName:
            "That name is reserved for a built-in preset."
        }
    }
}

private struct EqualizerBandColumn: View {
    let frequencyHz: Double
    @Binding var gain: Double

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingXS) {
            Text(formattedGain)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(gain == 0 ? .secondary : .primary)
                .frame(height: 14)

            VerticalGainSlider(value: $gain)
                .frame(width: 28, height: 200)

            Text(formattedFrequency)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 36)
    }

    private var formattedGain: String {
        if gain == 0 { return "0" }
        let prefix = gain > 0 ? "+" : ""
        return String(format: "%@%.0f", prefix, gain)
    }

    private var formattedFrequency: String {
        if frequencyHz >= 1000 {
            return String(format: "%.0fk", frequencyHz / 1000)
        }
        return String(format: "%.0f", frequencyHz)
    }
}

private struct VerticalGainSlider: View {
    @Binding var value: Double

    var body: some View {
        Slider(
            value: $value,
            in: EqualizerSettings.gainRangeDB,
            step: 0.5
        ) {
            Text(SpotiglassL10n.string("settings.eq.bandGain.accessibility"))
        }
        // SwiftUI's Slider is horizontal by default on macOS. Rotate it to render
        // a tall vertical band fader; the binding semantics stay correct.
        .rotationEffect(.degrees(-90))
        .frame(width: 200, height: 28)
        .frame(width: 28, height: 200)
        .accessibilityValue(Text(String(format: "%.1f dB", value)))
    }
}

private struct SavePresetSheet: View {
    @Binding var name: String
    @Binding var error: String?
    let onCancel: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
            Text(SpotiglassL10n.string("settings.eq.savePreset.title"))
                .font(.headline)
            Text(SpotiglassL10n.string("settings.eq.savePreset.message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(SpotiglassL10n.string("settings.eq.savePreset.field"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave(name) }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(SpotiglassL10n.string("settings.eq.savePreset.cancel"), role: .cancel, action: onCancel)
                Button(SpotiglassL10n.string("settings.eq.savePreset.save")) { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(width: 380)
    }
}
