import HeyEQQCore
import SwiftUI

/// The Equalizer window: shared header (on/off, status, sound bar, mode) above the Advanced or
/// Expert editor, or the settings pane.
struct EqualizerWindow: View {
    static let windowID = "equalizer"

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.showingSettings {
                SettingsView(model: model)
            } else {
                Group {
                    if model.mode == .expert {
                        ExpertEQView(model: model)
                    } else {
                        AdvancedEQView(model: model)
                    }
                }
                .opacity(model.enabled ? 1 : 0.6)
                .environment(\.spectrumFrame, model.showAnalyzer ? model.spectrum : nil)
            }
        }
        .padding(20)
        .frame(minWidth: 800, minHeight: 720)
        .onAppear {
            if model.mode == .simple && !model.showingSettings { model.mode = .advanced }
            model.startMetering()
            model.startSpectrum()
        }
        .onDisappear {
            model.stopSpectrum()
            model.stopMetering()
            model.showingSettings = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle("Equalizer", isOn: $model.enabled)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text("HeyEQQ").font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Circle().fill(model.status.color).frame(width: 7, height: 7)
                    Text(model.status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                SpectrumBars(frame: model.level > 0 ? model.spectrum : nil, barCount: 24)
                    .frame(height: 28)
                LevelMeter(level: model.level)
            }
            .frame(width: 140)

            Toggle(isOn: Binding(get: { model.bypassed }, set: { model.setBypass($0) })) {
                Text("Bypass")
            }
            .toggleStyle(.button)
            .fixedSize()
            .disabled(!model.enabled)
            .help(bypassHelp)

            Toggle(isOn: $model.showAnalyzer) {
                Image(systemName: "waveform.path.ecg")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Show the live spectrum behind the EQ curve")

            Picker("Mode", selection: Binding(get: { model.mode == .expert ? EQMode.expert : .advanced },
                                              set: { model.mode = $0; model.showingSettings = false })) {
                Text("Advanced").tag(EQMode.advanced)
                Text("Expert").tag(EQMode.expert)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Toggle(isOn: $model.showingSettings) {
                Image(systemName: "gearshape")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Settings: shortcuts, balance, per-device presets")
        }
        .card()
    }

    private var bypassHelp: String {
        let shortcut = model.shortcutText(for: .bypass)
        return "Compare with the unprocessed sound" + (shortcut.isEmpty ? "" : " (\(shortcut) from anywhere)")
    }
}
