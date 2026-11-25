import HeyEQQCore
import SwiftUI

/// Advanced mode: 10-band graphic EQ with preamp, response curve, presets and per-device presets.
/// Shown inside `EqualizerWindow`.
struct AdvancedEQView: View {
    @Bindable var model: AppModel

    @State private var showingSave = false
    @State private var renaming: Preset?
    @State private var deleting: Preset?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            ResponseCurveView(curve: model.advancedCurve)
                .frame(height: 170)
            faders
                .frame(height: 230)
            deviceRow
        }
        .alert("Save Preset", isPresented: $showingSave) {
            TextField("Name", text: $draftName)
            Button("Save") { model.saveUserPreset(named: draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current 10 bands and preamp.")
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") { if let p = renaming { model.renameUserPreset(p, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let p = deleting { model.deleteUserPreset(p) } }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("10-Band Graphic EQ").font(.headline)
            Spacer()
            presetMenu
        }
    }

    private var presetMenu: some View {
        let active = model.activeAdvancedPreset
        return Menu {
            Section("Built-in") {
                ForEach(Preset.advanced) { p in presetButton(p, active: active) }
            }
            if !model.userPresets.isEmpty {
                Section("My Presets") {
                    ForEach(model.userPresets) { p in presetButton(p, active: active) }
                }
            }
            Divider()
            Button("Save as New Preset…") {
                draftName = active.map { "\($0.name) copy" } ?? "My Preset"
                showingSave = true
            }
            if let active, !active.isBuiltIn {
                Button("Rename “\(active.name)”…") { draftName = active.name; renaming = active }
                Button("Delete “\(active.name)”…", role: .destructive) { deleting = active }
            }
        } label: {
            Text(active?.name ?? "Custom").frame(minWidth: 110)
        }
        .fixedSize()
    }

    private func presetButton(_ p: Preset, active: Preset?) -> some View {
        Button { model.applyAdvanced(p) } label: {
            if p == active { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }

    // MARK: Faders

    private var faders: some View {
        HStack(alignment: .top, spacing: 0) {
            VerticalGainSlider(value: Binding(get: { model.advancedPreamp }, set: { model.setPreamp($0) }),
                               range: EQCurve.preampRange, label: "Preamp", tint: .orange)
            Divider().padding(.horizontal, 12)
            ForEach(EQCurve.graphicFrequencies.indices, id: \.self) { i in
                VerticalGainSlider(value: Binding(get: { model.advancedGains[i] },
                                                  set: { model.setAdvancedGain($0, at: i) }),
                                   range: EQCurve.gainRange,
                                   label: frequencyLabel(EQCurve.graphicFrequencies[i]))
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(model.enabled ? 1 : 0.5)
    }

    // MARK: Per-device preset

    @ViewBuilder
    private var deviceRow: some View {
        HStack {
            if let device = model.currentDevice {
                Text("When \(device.name) is active, use:")
                    .font(.callout)
                Picker("Device preset", selection: Binding(
                    get: { model.assignedPreset(forDevice: device.uid)?.id },
                    set: { id in model.assign(model.advancedPresets.first { $0.id == id }, toDevice: device.uid) }
                )) {
                    Text("Nothing (keep current)").tag(String?.none)
                    Divider()
                    ForEach(model.advancedPresets) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text("Turn the equalizer on to set a preset for the current output device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Flat") { model.applyAdvanced(.advancedFlat) }
        }
    }
}
