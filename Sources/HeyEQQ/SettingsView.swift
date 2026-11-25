import Carbon.HIToolbox
import HeyEQQCore
import SwiftUI

/// The Equalizer window's settings pane: shortcuts, balance/mono, per-device presets, general.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Keyboard Shortcuts", note: "These work from any app. Click a shortcut, then press the new keys (with ⌘, ⌥ or ⌃). Esc cancels.") {
                    ForEach(ShortcutAction.allCases) { action in
                        HStack {
                            Text(action.label)
                            Spacer()
                            ShortcutRecorder(model: model, action: action)
                        }
                    }
                }

                section("Sound", note: "Balance and mono apply to the left/right pair, after the EQ. Bypass turns them off too.") {
                    HStack(spacing: 12) {
                        Text("Balance")
                        BalanceControl(model: model)
                        Text(balanceText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .trailing)
                        Button("Reset") { model.balance = 0 }
                            .disabled(model.balance == 0)
                    }
                    Toggle("Mono (play the same sound on both sides)", isOn: $model.mono)
                        .toggleStyle(.checkbox)
                }

                section("Output Devices", note: "Pick what each device switches to when it becomes the active output. It can be a preset from any mode.") {
                    if model.devices.isEmpty {
                        Text("No output devices found.").foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { device in
                        HStack {
                            Image(systemName: device.uid == model.currentDevice?.uid ? "speaker.wave.2.fill" : "speaker")
                                .foregroundStyle(device.uid == model.currentDevice?.uid ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            Text(device.name)
                            Spacer()
                            DevicePresetPicker(model: model, device: device)
                        }
                    }
                }

                section("General") {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.checkbox)
                    if let error = model.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Toggle("Show the live spectrum behind the EQ curve", isOn: $model.showAnalyzer)
                        .toggleStyle(.checkbox)
                    Toggle("Suggest a headphone curve when a new output device connects", isOn: $model.suggestHeadphoneCurves)
                        .toggleStyle(.checkbox)
                    Text("To check for a match, HeyEQQ downloads the public AutoEQ headphone list from GitHub. Device names never leave your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("HeyEQQ \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.showingSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { model.refreshDevices(); model.refreshLaunchAtLogin() }
    }

    private var balanceText: String {
        let percent = Int((abs(model.balance) * 100).rounded())
        return percent == 0 ? "Centre" : "\(percent)% \(model.balance < 0 ? "left" : "right")"
    }

    private func section(_ title: String, note: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            content()
        }
        .card()
    }
}

/// Left/right balance slider that snaps to the centre.
struct BalanceControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text("L").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.balance }, set: { raw in
                let value = abs(raw) < 0.06 ? 0 : (raw * 20).rounded() / 20
                if value != model.balance { model.balance = value }
            }), in: -1...1)
            Text("R").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu { Button("Centre") { model.balance = 0 } }
        .accessibilityLabel("Balance")
    }
}

/// Menu that chooses what a device switches to when it becomes active: nothing, or a preset of any mode.
struct DevicePresetPicker: View {
    @Bindable var model: AppModel
    let device: OutputDevice

    var body: some View {
        let current = model.assignment(forDevice: device.uid)
        Menu {
            item("Nothing (keep current settings)", nil, current)
            Section("Simple") {
                ForEach(Preset.simple) { p in item(p.name, DeviceAssignment(mode: .simple, presetID: p.id), current) }
            }
            Section("Advanced") {
                ForEach(model.advancedPresets) { p in item(p.name, DeviceAssignment(mode: .advanced, presetID: p.id), current) }
            }
            Section("Expert") {
                ForEach(model.expertPresets) { p in item(p.name, DeviceAssignment(mode: .expert, presetID: p.id), current) }
            }
        } label: {
            Text(current.flatMap { a in model.presetName(for: a).map { "\(a.mode.label) · \($0)" } } ?? "Nothing")
        }
        .fixedSize()
        .help("What \(device.name) switches to when it becomes the active output")
    }

    private func item(_ name: String, _ assignment: DeviceAssignment?, _ current: DeviceAssignment?) -> some View {
        Button { model.assign(assignment, toDevice: device.uid) } label: {
            if assignment == current { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}

/// Shows an action's shortcut; click to record a new one, ✕ to remove it.
struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    let action: ShortcutAction

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if model.unavailableShortcuts.contains(action) {
                Text("Used by another app").font(.caption).foregroundStyle(.orange)
            }
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : (model.shortcuts[action]?.display ?? "Record Shortcut"))
                    .frame(minWidth: 120)
            }
            Button { model.setShortcut(nil, for: action) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .opacity(model.shortcuts[action] != nil && !recording ? 1 : 0)
            .disabled(model.shortcuts[action] == nil || recording)
            .help("Remove this shortcut")
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        model.setShortcutsSuspended(true) // otherwise pressing an existing shortcut would trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let shortcut = Shortcut(event: event) {
                stop()
                model.setShortcut(shortcut, for: action)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.setShortcutsSuspended(false)
    }
}
