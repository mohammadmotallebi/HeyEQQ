import HeyEQQCore
import SwiftUI

/// Expert mode › Per-App: give individual apps their own curve (or no EQ).
struct PerAppView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Give apps their own EQ and volume. Apps on “Main EQ” use the curve of the current mode; “No EQ” plays an app untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                if model.perAppList.isEmpty {
                    Text("No apps are using audio right now. Start playing something and it appears here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.perAppList) { app in
                    AppRow(app: app, model: model)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 320)

            Text("Safari and other WebKit-based apps play through a shared system process, so they can't be separated. Chrome, Firefox, Spotify, Music, Zoom and most other apps work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refreshAudioApps() }
    }
}

private struct AppRow: View {
    let app: AudioApp
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { volume },
                                  set: { model.setAppVolume($0, for: app.bundleID, name: app.name) }), in: 0...1)
                .frame(width: 110)
                .help("Volume of \(app.name) (right-click to reset)")
                .contextMenu { Button("Reset to 100%") { model.setAppVolume(1, for: app.bundleID, name: app.name) } }
            Text("\(Int((volume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(volume < 1 ? .primary : .secondary)
                .frame(width: 42, alignment: .trailing)
            Picker("EQ for \(app.name)", selection: Binding(
                get: { model.appRules[app.bundleID] },
                set: { model.setAppRule($0, for: app.bundleID, name: app.name) }
            )) {
                Text("Main EQ").tag(String?.none)
                Text("No EQ").tag(Optional(AppModel.AppRule.noEQ))
                Divider()
                ForEach(model.expertPresets) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.vertical, 2)
    }

    private var volume: Double { model.appVolumes[app.bundleID] ?? 1 }

    private var statusText: String {
        var parts: [String] = [app.isPlaying ? "Playing" : app.isRunning ? "Idle" : "Not running"]
        if model.activeApps.contains(app.bundleID) { parts.append("own settings active") }
        return parts.joined(separator: " · ")
    }
}
