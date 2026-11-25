import HeyEQQCore
import SwiftUI

/// The menu-bar popover.
struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            StatusRow(status: model.status, openSettings: model.openPrivacySettings)
            if !model.activeApps.isEmpty {
                Label("\(model.activeApps.count) app\(model.activeApps.count == 1 ? "" : "s") with their own EQ",
                      systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $model.mode) {
                ForEach(EQMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch model.mode {
                case .simple: simpleContent
                case .advanced, .expert: windowModeContent
                }
            }
            .opacity(model.enabled ? 1 : 0.5)

            LevelMeter(level: model.level)

            HStack {
                Toggle(isOn: Binding(get: { model.bypassed }, set: { model.setBypass($0) })) {
                    Text("Bypass (compare)")
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(model.hotKeyAvailable ? GlobalHotKey.bypassDisplay : "shortcut in use")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.enabled)

            Divider()

            Picker("Output", selection: $model.outputUID) {
                Text("System Default").tag(String?.none)
                Divider()
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Reset") {
                    switch model.mode {
                    case .simple: model.applySimple(.simpleFlat)
                    case .advanced: model.applyAdvanced(.advancedFlat)
                    case .expert: model.applyExpert(.starter)
                    }
                }
                Spacer()
                Button("Quit HeyEQQ") { model.quit() }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.startMetering(); model.refreshDevices(); model.refreshLaunchAtLogin() }
        .onDisappear { model.stopMetering() }
    }

    private var header: some View {
        HStack {
            Text("HeyEQQ").font(.title3.weight(.semibold))
            Spacer()
            Toggle("Equalizer", isOn: $model.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: Simple

    private var simpleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            PresetGrid(presets: Preset.simple, active: model.activeSimplePreset, apply: model.applySimple)
            VStack(spacing: 10) {
                ForEach(AppModel.simpleBandLabels.indices, id: \.self) { i in
                    BandSlider(label: AppModel.simpleBandLabels[i],
                               value: Binding(get: { model.simpleGains[i] },
                                              set: { model.setSimpleGain($0, at: i) }))
                }
            }
        }
    }

    // MARK: Advanced / Expert (summary; editing happens in the Equalizer window)

    private var windowModeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.mode == .expert ? "Curve" : "Preset").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.mode == .expert {
                    Menu(model.activeExpertPreset?.name ?? "Custom") {
                        ForEach(ExpertPreset.builtIn) { p in Button(p.name) { model.applyExpert(p) } }
                        if !model.userExpertPresets.isEmpty {
                            Divider()
                            ForEach(model.userExpertPresets) { p in Button(p.name) { model.applyExpert(p) } }
                        }
                    }
                    .fixedSize()
                } else {
                    Menu(model.activeAdvancedPreset?.name ?? "Custom") {
                        ForEach(Preset.advanced) { p in Button(p.name) { model.applyAdvanced(p) } }
                        if !model.userPresets.isEmpty {
                            Divider()
                            ForEach(model.userPresets) { p in Button(p.name) { model.applyAdvanced(p) } }
                        }
                    }
                    .fixedSize()
                }
            }
            ResponseCurveView(curve: model.activeCurve, rangeDB: model.mode == .expert ? 18 : 12, showsLabels: false)
                .frame(height: 64)
            Button {
                openWindow(id: EqualizerWindow.windowID)
                NSApp.activate()
            } label: {
                Label("Open Equalizer…", systemImage: "slider.vertical.3")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StatusRow: View {
    let status: EQEngine.Status
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(status.text).font(.callout).lineLimit(3)
            }
            if showsPermissionHint {
                Button("No effect? Check System Audio Recording permission…", action: openSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var showsPermissionHint: Bool {
        switch status {
        case .starting, .failed: true
        default: false
        }
    }
}

private struct PresetGrid: View {
    let presets: [Preset]
    let active: Preset?
    let apply: (Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preset").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(active?.name ?? "Custom").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets) { preset in
                    Button { apply(preset) } label: {
                        Text(preset.name)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(active == preset ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(active == preset ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BandSlider: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 50, alignment: .leading)
            Slider(value: $value, in: EQCurve.gainRange)
            Text(String(format: "%+.1f dB", value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .contextMenu { Button("Reset \(label)") { value = 0 } }
    }
}
