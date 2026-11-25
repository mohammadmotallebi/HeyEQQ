import HeyEQQCore
import SwiftUI

/// The Equalizer window: shared header (on/off, status, meter, mode) + Advanced or Expert editor.
struct EqualizerWindow: View {
    static let windowID = "equalizer"

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Toggle("Equalizer", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text("HeyEQQ").font(.title3.weight(.semibold))
                    HStack(spacing: 5) {
                        Circle().fill(model.status.color).frame(width: 7, height: 7)
                        Text(model.status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Toggle(isOn: Binding(get: { model.bypassed }, set: { model.setBypass($0) })) {
                    Text("Bypass")
                }
                .toggleStyle(.button)
                .help("Compare with the unprocessed sound (\(GlobalHotKey.bypassDisplay) from anywhere)")
                Toggle(isOn: $model.showAnalyzer) {
                    Image(systemName: "waveform.path.ecg")
                }
                .toggleStyle(.button)
                .help("Show the live spectrum behind the EQ curve")
                LevelMeter(level: model.level).frame(width: 90)
                Picker("Mode", selection: Binding(get: { model.mode == .expert ? EQMode.expert : .advanced },
                                                  set: { model.mode = $0 })) {
                    Text("Advanced").tag(EQMode.advanced)
                    Text("Expert").tag(EQMode.expert)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            Divider()

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
        .padding(20)
        .frame(minWidth: 760, minHeight: 620)
        .onAppear {
            if model.mode == .simple { model.mode = .advanced }
            model.startMetering()
            model.startAnalyzer()
        }
        .onDisappear {
            model.stopAnalyzer()
            model.stopMetering()
        }
    }
}
