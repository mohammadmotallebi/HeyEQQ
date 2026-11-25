import HeyEQQCore
import SwiftUI

/// The menu-bar popover.
struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            soundBar

            Picker("Mode", selection: $model.mode) {
                ForEach(EQMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)

            Group {
                switch model.mode {
                case .simple: simpleContent
                case .advanced: advancedContent
                case .expert: expertContent
                }
            }
            .card()
            .opacity(model.enabled ? 1 : 0.5)

            settings
            footer
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            model.startMetering(); model.startSpectrumBars()
            model.refreshDevices(); model.refreshLaunchAtLogin()
        }
        .onDisappear { model.stopSpectrumBars(); model.stopMetering() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HeyEQQ").font(.title2.weight(.semibold))
                StatusRow(status: model.status, openSettings: model.openPrivacySettings)
                if !model.activeApps.isEmpty {
                    Label("\(model.activeApps.count) app\(model.activeApps.count == 1 ? "" : "s") with their own EQ",
                          systemImage: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Equalizer", isOn: $model.enabled)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
        }
    }

    // MARK: Sound bar (live spectrum + level, bypass)

    private var soundBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The input peak falls to 0 when nothing plays, which also clears a stale last frame.
            SpectrumBars(frame: model.level > 0 ? model.spectrum : nil)
                .frame(height: 48)
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
        }
        .card()
    }

    // MARK: Output, launch at login

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
        .card()
    }

    private var footer: some View {
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

    private func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var openEqualizerButton: some View {
        Button {
            openWindow(id: EqualizerWindow.windowID)
            NSApp.activate()
        } label: {
            Label("Open Equalizer…", systemImage: "slider.vertical.3")
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Simple

    private var simpleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            PresetGrid(presets: Preset.simple, active: model.activeSimplePreset, apply: model.applySimple)
            ResponseCurveView(curve: model.activeCurve, showsLabels: false)
                .frame(height: 64)
            VStack(spacing: 10) {
                ForEach(AppModel.simpleBandLabels.indices, id: \.self) { i in
                    BandSlider(label: AppModel.simpleBandLabels[i],
                               value: Binding(get: { model.simpleGains[i] },
                                              set: { model.setSimpleGain($0, at: i) }))
                }
            }
        }
    }

    // MARK: Advanced (10 faders + preamp, editable here; presets are managed in the window)

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("10-Band Graphic EQ")
                Spacer()
                Menu(model.activeAdvancedPreset?.name ?? "Custom") {
                    ForEach(Preset.advanced) { p in Button(p.name) { model.applyAdvanced(p) } }
                    if !model.userPresets.isEmpty {
                        Divider()
                        ForEach(model.userPresets) { p in Button(p.name) { model.applyAdvanced(p) } }
                    }
                }
                .fixedSize()
            }
            ResponseCurveView(curve: model.advancedCurve)
                .frame(height: 96)
            HStack(alignment: .top, spacing: 0) {
                VerticalGainSlider(value: Binding(get: { model.advancedPreamp }, set: { model.setPreamp($0) }),
                                   range: EQCurve.preampRange, label: "Pre", tint: .orange, compact: true)
                    .frame(maxWidth: .infinity)
                    .help("Preamp")
                Divider().padding(.horizontal, 4)
                ForEach(EQCurve.graphicFrequencies.indices, id: \.self) { i in
                    VerticalGainSlider(value: Binding(get: { model.advancedGains[i] },
                                                      set: { model.setAdvancedGain($0, at: i) }),
                                       range: EQCurve.gainRange,
                                       label: frequencyLabel(EQCurve.graphicFrequencies[i]), compact: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150)
            openEqualizerButton
        }
    }

    // MARK: Expert (graph + band list; full editing happens in the Equalizer window)

    private var expertContent: some View {
        let curve = model.expertCurve
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Parametric EQ",
                             detail: "\(curve.bands.count) band\(curve.bands.count == 1 ? "" : "s") · preamp \(String(format: "%+.1f dB", curve.preampDB))")
                Spacer()
                Menu(model.activeExpertPreset?.name ?? "Custom") {
                    ForEach(ExpertPreset.builtIn) { p in Button(p.name) { model.applyExpert(p) } }
                    if !model.userExpertPresets.isEmpty {
                        Divider()
                        ForEach(model.userExpertPresets) { p in Button(p.name) { model.applyExpert(p) } }
                    }
                }
                .fixedSize()
            }
            ResponseCurveView(curve: curve, rangeDB: 18, showsBandCurves: true, showsBandMarkers: true)
                .frame(height: 130)
            bandList(curve)
            openEqualizerButton
        }
    }

    @ViewBuilder
    private func bandList(_ curve: EQCurve) -> some View {
        let rowHeight: CGFloat = 20, visibleRows = 6
        VStack(spacing: 2) {
            BandRow(cells: ["Type", "Freq", "Gain", "Q"], isHeader: true) { Color.clear }
                .foregroundStyle(.secondary)
            let rows = VStack(spacing: 2) {
                ForEach(curve.bands.indices, id: \.self) { i in
                    let band = curve.bands[i]
                    BandRow(cells: [band.type.label,
                                    frequencyText(band.frequency),
                                    band.type.usesGain ? String(format: "%+.1f dB", band.gainDB) : "—",
                                    String(format: "%.2f", band.q)]) {
                        Button { model.updateExpertBand(at: i) { $0.isEnabled.toggle() } } label: {
                            ZStack {
                                Circle().fill(bandColor(i))
                                Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(band.isEnabled ? "Turn band \(i + 1) off" : "Turn band \(i + 1) on")
                    }
                    .frame(height: rowHeight)
                    .opacity(band.isEnabled ? 1 : 0.4)
                }
            }
            if curve.bands.count > visibleRows {
                ScrollView { rows }.frame(height: CGFloat(visibleRows) * (rowHeight + 2))
            } else {
                rows
            }
        }
    }
}

/// One line of the popover's Expert band list: a leading badge, then Type / Freq / Gain / Q.
private struct BandRow<Badge: View>: View {
    let cells: [String]
    var isHeader = false
    @ViewBuilder let badge: Badge

    var body: some View {
        HStack(spacing: 8) {
            badge.frame(width: 16, height: 16)
            Text(cells[0]).frame(maxWidth: .infinity, alignment: .leading)
            Text(cells[1]).frame(width: 76, alignment: .trailing)
            Text(cells[2]).frame(width: 68, alignment: .trailing)
            Text(cells[3]).frame(width: 44, alignment: .trailing)
        }
        .font(isHeader ? .caption2 : .callout.monospacedDigit())
        .lineLimit(1)
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
