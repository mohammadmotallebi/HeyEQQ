import AppKit
import HeyEQQCore
import Observation
import ServiceManagement

enum EQMode: String, CaseIterable, Identifiable, Codable {
    case simple, advanced, expert
    var id: String { rawValue }
    var label: String {
        switch self { case .simple: "Simple"; case .advanced: "Advanced"; case .expert: "Expert" }
    }
}

/// What an output device switches to when it becomes active: a mode and one of that mode's presets.
struct DeviceAssignment: Codable, Hashable {
    var mode: EQMode
    var presetID: String
}

/// Things a global keyboard shortcut can do.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case bypass, nextPreset, previousPreset
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bypass: "Bypass (compare)"
        case .nextPreset: "Next preset"
        case .previousPreset: "Previous preset"
        }
    }
}

/// UI state for the app. Persists settings and drives `EQEngine` with the active mode's curve.
@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let enabled = "enabled"
        static let mode = "mode"
        static let simpleGains = "gains" // name kept from the first version
        static let advancedGains = "advancedGains"
        static let advancedPreamp = "advancedPreamp"
        static let outputUID = "outputUID"
        static let deviceAssignments = "deviceAssignments"
        static let expertCurve = "expertCurve"
        static let appRules = "appRules"
        static let appRuleNames = "appRuleNames"
        static let showAnalyzer = "showAnalyzer"
        static let deviceAssignmentsV2 = "deviceAssignmentsV2"
        static let shortcuts = "shortcuts"
        static let balance = "balance"
        static let mono = "mono"
    }

    static let simpleBandLabels = ["Bass", "Mid", "Treble"]

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Key.enabled)
            engine.setEnabled(enabled)
        }
    }

    var mode: EQMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            pushCurve()
        }
    }

    /// nil = follow the system default output.
    var outputUID: String? {
        didSet {
            defaults.set(outputUID, forKey: Key.outputUID)
            engine.setPreferredOutput(uid: outputUID)
        }
    }

    private(set) var simpleGains: [Double]
    private(set) var advancedGains: [Double]
    private(set) var advancedPreamp: Double
    private(set) var userPresets: [Preset]
    private(set) var expertCurve: EQCurve
    private(set) var userExpertPresets: [ExpertPreset]
    /// Output device UID → mode + preset, applied when that device becomes active.
    private(set) var deviceAssignments: [String: DeviceAssignment]

    /// Left/right balance, -1 (left only) … 0 … +1 (right only).
    var balance: Double {
        didSet {
            defaults.set(balance, forKey: Key.balance)
            engine.setBalance(balance)
        }
    }
    /// Sums left and right to mono.
    var mono: Bool {
        didSet {
            defaults.set(mono, forKey: Key.mono)
            engine.setMono(mono)
        }
    }

    /// Global keyboard shortcuts. An action without an entry has no shortcut.
    private(set) var shortcuts: [ShortcutAction: Shortcut]
    /// Actions whose shortcut couldn't be registered because another app already uses it.
    private(set) var unavailableShortcuts: Set<ShortcutAction> = []
    /// Whether the Equalizer window shows the settings pane instead of the editor (not persisted).
    var showingSettings = false

    /// Per-app EQ: app bundle ID → `AppRule.noEQ` or an Expert curve id.
    private(set) var appRules: [String: String]
    /// Display names for apps with rules (so they can be shown while not running).
    private(set) var appRuleNames: [String: String]
    /// Apps currently connected to the audio system.
    private(set) var audioApps: [AudioApp] = []
    /// Apps currently equalized by their own pipeline.
    private(set) var activeApps: Set<String> = []

    /// A/B: audio passes unprocessed (toggled with the bypass shortcut). Not persisted.
    private(set) var bypassed = false

    /// Whether the Equalizer window draws the live spectrum behind the EQ curve.
    var showAnalyzer: Bool {
        didSet { defaults.set(showAnalyzer, forKey: Key.showAnalyzer) }
    }
    /// Latest analyzer frame while a view showing it is open.
    private(set) var spectrum: SpectrumFrame?

    private(set) var launchAtLogin = false
    private(set) var launchAtLoginError: String?

    private(set) var status: EQEngine.Status = .off
    private(set) var devices: [OutputDevice] = []
    /// Smoothed input level, 0...1 on a dB scale.
    private(set) var level: Double = 0

    @ObservationIgnored private let engine = EQEngine()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var lastDeviceUID: String?
    @ObservationIgnored private var hotKeys: [GlobalHotKey] = []
    @ObservationIgnored private var shortcutsSuspended = false
    @ObservationIgnored private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private var spectrumClients = 0
    @ObservationIgnored private var peakHoldDB: [Float] = []
    @ObservationIgnored private var peakHoldAge: [Int] = []

    init() {
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        mode = EQMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .simple
        outputUID = defaults.string(forKey: Key.outputUID)
        let simple = defaults.array(forKey: Key.simpleGains) as? [Double] ?? []
        simpleGains = simple.count == EQCurve.simpleBandCount ? simple : Preset.simpleFlat.gains
        let advanced = defaults.array(forKey: Key.advancedGains) as? [Double] ?? []
        advancedGains = advanced.count == EQCurve.graphicFrequencies.count ? advanced : Preset.advancedFlat.gains
        advancedPreamp = defaults.double(forKey: Key.advancedPreamp)
        userPresets = UserPresetStore.load()
        expertCurve = (defaults.data(forKey: Key.expertCurve)).flatMap { try? JSONDecoder().decode(EQCurve.self, from: $0) }
            ?? ExpertPreset.starter.curve
        userExpertPresets = JSONFileStore.load([ExpertPreset].self, from: Self.expertPresetsFile) ?? []
        appRules = defaults.dictionary(forKey: Key.appRules) as? [String: String] ?? [:]
        appRuleNames = defaults.dictionary(forKey: Key.appRuleNames) as? [String: String] ?? [:]
        showAnalyzer = defaults.object(forKey: Key.showAnalyzer) as? Bool ?? true
        if let data = defaults.data(forKey: Key.deviceAssignmentsV2),
           let stored = try? JSONDecoder().decode([String: DeviceAssignment].self, from: data) {
            deviceAssignments = stored
        } else {
            // Before per-device presets worked in every mode, they were Advanced preset ids.
            let old = defaults.dictionary(forKey: Key.deviceAssignments) as? [String: String] ?? [:]
            deviceAssignments = old.mapValues { DeviceAssignment(mode: .advanced, presetID: $0) }
        }
        balance = min(max(defaults.double(forKey: Key.balance), -1), 1)
        mono = defaults.bool(forKey: Key.mono)
        if let data = defaults.data(forKey: Key.shortcuts),
           let stored = try? JSONDecoder().decode([ShortcutAction: Shortcut].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = [.bypass: .defaultBypass]
        }

        engine.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.handle(status) }
        }
        engine.onDevicesChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        engine.onProcessesChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshAudioApps() }
        }
        engine.onActiveAppsChange = { [weak self] apps in
            MainActor.assumeIsolated { self?.activeApps = apps }
        }
        refreshDevices()
        refreshAudioApps()
        pushCurve()
        pushAppRules()
        engine.setPreferredOutput(uid: outputUID)
        engine.setBalance(balance)
        engine.setMono(mono)
        engine.setEnabled(enabled)

        registerHotKeys()
        refreshLaunchAtLogin()
    }

    // MARK: - Keyboard shortcuts

    /// Sets or clears (nil) an action's shortcut. A combination moves to the action it was set on last.
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (other, existing) in shortcuts where other != action && existing == shortcut { shortcuts[other] = nil }
        }
        shortcuts[action] = shortcut
        if let data = try? JSONEncoder().encode(shortcuts) { defaults.set(data, forKey: Key.shortcuts) }
        registerHotKeys()
    }

    /// While a shortcut is being recorded, the existing ones must not fire.
    func setShortcutsSuspended(_ suspended: Bool) {
        shortcutsSuspended = suspended
        registerHotKeys()
    }

    /// "⌥⌘E", or why there is nothing to show.
    func shortcutText(for action: ShortcutAction) -> String {
        guard let shortcut = shortcuts[action] else { return "" }
        return unavailableShortcuts.contains(action) ? "\(shortcut.display) in use" : shortcut.display
    }

    private func registerHotKeys() {
        hotKeys.forEach { $0.unregister() }
        hotKeys = []
        unavailableShortcuts = []
        guard !shortcutsSuspended else { return }
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            if let hotKey = GlobalHotKey(shortcut, action: { [weak self] in self?.perform(action) }) {
                hotKeys.append(hotKey)
            } else {
                unavailableShortcuts.insert(action)
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .bypass: toggleBypass()
        case .nextPreset: stepPreset(by: 1)
        case .previousPreset: stepPreset(by: -1)
        }
    }

    /// Moves to the next/previous preset of the current mode, wrapping around. From custom
    /// settings, "next" goes to the first preset and "previous" to the last.
    func stepPreset(by delta: Int) {
        func target(_ count: Int, _ current: Int?) -> Int? {
            guard count > 0 else { return nil }
            guard let current else { return delta > 0 ? 0 : count - 1 }
            return ((current + delta) % count + count) % count
        }
        switch mode {
        case .simple:
            let list = Preset.simple
            if let i = target(list.count, activeSimplePreset.flatMap(list.firstIndex)) { applySimple(list[i]) }
        case .advanced:
            let list = advancedPresets
            if let i = target(list.count, activeAdvancedPreset.flatMap(list.firstIndex)) { applyAdvanced(list[i]) }
        case .expert:
            let list = expertPresets
            if let i = target(list.count, activeExpertPreset.flatMap(list.firstIndex)) { applyExpert(list[i]) }
        }
    }

    // MARK: - Bypass, launch at login

    func toggleBypass() { setBypass(!bypassed) }

    func setBypass(_ on: Bool) {
        bypassed = on
        engine.setBypass(on)
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Spectrum analyzer (runs only while a view showing it is open)

    func startSpectrum() {
        spectrumClients += 1
        updateAnalyzer()
    }

    func stopSpectrum() {
        spectrumClients = max(0, spectrumClients - 1)
        updateAnalyzer()
    }

    private func updateAnalyzer() {
        let on = spectrumClients > 0
        engine.setAnalyzerEnabled(on)
        if !on { clearSpectrum() }
    }

    private func clearSpectrum() {
        spectrum = nil
        analyzer.reset()
        peakHoldDB = []
        peakHoldAge = []
    }

    private func tickAnalyzer() {
        guard spectrumClients > 0 else { return }
        guard let (samples, rate) = engine.analyzerSamples(count: analyzer.fftSize) else {
            if spectrum != nil { clearSpectrum() }
            return
        }
        let levels = analyzer.analyze(samples, sampleRate: rate)

        // Peak hold: each band's highest recent level stays for ~0.6 s, then falls.
        if peakHoldDB.count != levels.count {
            peakHoldDB = levels
            peakHoldAge = Array(repeating: 0, count: levels.count)
        }
        for i in levels.indices {
            if levels[i] >= peakHoldDB[i] {
                peakHoldDB[i] = levels[i]
                peakHoldAge[i] = 0
            } else {
                peakHoldAge[i] += 1
                if peakHoldAge[i] > 18 { peakHoldDB[i] = max(levels[i], peakHoldDB[i] - 1.2) }
            }
        }
        spectrum = SpectrumFrame(frequencies: analyzer.bandFrequencies, levelsDB: levels, peaksDB: peakHoldDB)
    }

    var currentDevice: OutputDevice? {
        if case .running(let device) = status { device } else { nil }
    }

    /// The curve the engine is running for the current mode.
    var activeCurve: EQCurve {
        switch mode {
        case .simple: .simple(simpleGains)
        case .advanced: advancedCurve
        case .expert: expertCurve
        }
    }
    var advancedCurve: EQCurve { .graphic(advancedGains, preampDB: advancedPreamp) }

    private func pushCurve() { engine.setCurve(activeCurve) }

    private static func snap(_ db: Double, to range: ClosedRange<Double>) -> Double {
        min(max((db * 2).rounded() / 2, range.lowerBound), range.upperBound) // 0.5 dB steps
    }

    // MARK: - Simple mode

    var activeSimplePreset: Preset? { Preset.simple.first { $0.gains == simpleGains } }

    func setSimpleGain(_ db: Double, at index: Int) {
        let value = Self.snap(db, to: EQCurve.gainRange)
        guard simpleGains.indices.contains(index), simpleGains[index] != value else { return }
        simpleGains[index] = value
        defaults.set(simpleGains, forKey: Key.simpleGains)
        if mode == .simple { pushCurve() }
    }

    func applySimple(_ preset: Preset) {
        simpleGains = preset.gains
        defaults.set(simpleGains, forKey: Key.simpleGains)
        if mode == .simple { pushCurve() }
    }

    // MARK: - Advanced mode

    var advancedPresets: [Preset] { Preset.advanced + userPresets }

    var activeAdvancedPreset: Preset? {
        advancedPresets.first { $0.gains == advancedGains && $0.preampDB == advancedPreamp }
    }

    func setAdvancedGain(_ db: Double, at index: Int) {
        let value = Self.snap(db, to: EQCurve.gainRange)
        guard advancedGains.indices.contains(index), advancedGains[index] != value else { return }
        advancedGains[index] = value
        saveAdvanced()
    }

    func setPreamp(_ db: Double) {
        let value = Self.snap(db, to: EQCurve.preampRange)
        guard value != advancedPreamp else { return }
        advancedPreamp = value
        saveAdvanced()
    }

    func applyAdvanced(_ preset: Preset) {
        advancedGains = preset.gains
        advancedPreamp = preset.preampDB
        saveAdvanced()
    }

    private func saveAdvanced() {
        defaults.set(advancedGains, forKey: Key.advancedGains)
        defaults.set(advancedPreamp, forKey: Key.advancedPreamp)
        if mode == .advanced { pushCurve() }
    }

    @discardableResult
    func saveUserPreset(named name: String) -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(id: "user.\(UUID().uuidString)", name: trimmed.isEmpty ? "My Preset" : trimmed,
                            gains: advancedGains, preampDB: advancedPreamp, isBuiltIn: false)
        userPresets.append(preset)
        UserPresetStore.save(userPresets)
        return preset
    }

    func renameUserPreset(_ preset: Preset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        userPresets[i].name = trimmed
        UserPresetStore.save(userPresets)
    }

    func deleteUserPreset(_ preset: Preset) {
        userPresets.removeAll { $0.id == preset.id }
        UserPresetStore.save(userPresets)
        removeAssignments(to: DeviceAssignment(mode: .advanced, presetID: preset.id))
    }

    // MARK: - Expert mode

    private static let expertPresetsFile = "expert-presets.json"

    var expertPresets: [ExpertPreset] { ExpertPreset.builtIn + userExpertPresets }
    var activeExpertPreset: ExpertPreset? { expertPresets.first { $0.curve == expertCurve } }

    func setExpertCurve(_ curve: EQCurve) {
        guard curve != expertCurve else { return }
        expertCurve = curve
        if let data = try? JSONEncoder().encode(curve) { defaults.set(data, forKey: Key.expertCurve) }
        if mode == .expert { pushCurve() }
    }

    func updateExpertBand(at index: Int, _ change: (inout EQBand) -> Void) {
        guard expertCurve.bands.indices.contains(index) else { return }
        var curve = expertCurve
        change(&curve.bands[index])
        curve.bands[index].frequency = min(max(curve.bands[index].frequency, 10), 22_000)
        curve.bands[index].q = min(max(curve.bands[index].q, 0.1), 24)
        curve.bands[index].gainDB = min(max(curve.bands[index].gainDB, -24), 24)
        setExpertCurve(curve)
    }

    /// Adds a flat peak band in the widest free gap of the spectrum; returns its index.
    @discardableResult
    func addExpertBand() -> Int? {
        guard expertCurve.bands.count < EQCurve.maxBands else { return nil }
        let used = ([20.0, 20_000] + expertCurve.bands.map(\.frequency)).sorted()
        var best = (gap: 0.0, f: 1_000.0)
        for (a, b) in zip(used, used.dropFirst()) where log2(b / a) > best.gap {
            best = (log2(b / a), (a * b).squareRoot())
        }
        var curve = expertCurve
        curve.bands.append(EQBand(type: .peak, frequency: best.f.rounded(), gainDB: 0, q: 1))
        setExpertCurve(curve)
        return curve.bands.count - 1
    }

    func removeExpertBand(at index: Int) {
        guard expertCurve.bands.indices.contains(index) else { return }
        var curve = expertCurve
        curve.bands.remove(at: index)
        setExpertCurve(curve)
    }

    func setExpertPreamp(_ db: Double) {
        var curve = expertCurve
        curve.preampDB = min(max((db * 10).rounded() / 10, -24), 24)
        setExpertCurve(curve)
    }

    /// Preamp that keeps the curve's highest boost at 0 dB (so the limiter never has to work).
    func autoExpertPreamp() {
        setExpertPreamp(-max(0, expertCurve.maxBoostDB()))
    }

    func applyExpert(_ preset: ExpertPreset) { setExpertCurve(preset.curve) }

    /// Imports Equalizer APO / AutoEQ text as the current curve and saves it as a user preset.
    func importExpert(_ text: String, name: String) throws -> EqualizerAPO.ImportResult {
        let result = try EqualizerAPO.parse(text)
        setExpertCurve(result.curve)
        // Importing the same thing twice shouldn't leave two identical curves.
        if !userExpertPresets.contains(where: { $0.name == name && $0.curve == expertCurve }) {
            saveExpertPreset(named: name)
        }
        return result
    }

    func exportExpert() -> String { EqualizerAPO.export(expertCurve) }

    func saveExpertPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        userExpertPresets.append(ExpertPreset(id: "userexp.\(UUID().uuidString)",
                                              name: trimmed.isEmpty ? "My Curve" : trimmed,
                                              curve: expertCurve, isBuiltIn: false))
        JSONFileStore.save(userExpertPresets, to: Self.expertPresetsFile)
    }

    func renameExpertPreset(_ preset: ExpertPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = userExpertPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        userExpertPresets[i].name = trimmed
        JSONFileStore.save(userExpertPresets, to: Self.expertPresetsFile)
    }

    func deleteExpertPreset(_ preset: ExpertPreset) {
        userExpertPresets.removeAll { $0.id == preset.id }
        JSONFileStore.save(userExpertPresets, to: Self.expertPresetsFile)
        // Apps using the deleted curve go back to the main EQ.
        for (app, id) in appRules where id == preset.id { setAppRule(nil, for: app, name: nil) }
        removeAssignments(to: DeviceAssignment(mode: .expert, presetID: preset.id))
    }

    // MARK: - Per-app EQ

    enum AppRule {
        static let noEQ = "noEQ"
    }

    /// nil = use the main EQ; `AppRule.noEQ`; or an Expert curve id.
    func setAppRule(_ rule: String?, for bundleID: String, name: String?) {
        appRules[bundleID] = rule
        if rule == nil { appRuleNames[bundleID] = nil } else if let name { appRuleNames[bundleID] = name }
        defaults.set(appRules, forKey: Key.appRules)
        defaults.set(appRuleNames, forKey: Key.appRuleNames)
        pushAppRules()
    }

    private func pushAppRules() {
        var curves: [String: EQCurve] = [:]
        for (app, rule) in appRules {
            if rule == AppRule.noEQ {
                curves[app] = .flat
            } else if let preset = expertPresets.first(where: { $0.id == rule }) {
                curves[app] = preset.curve
            }
        }
        engine.setAppRules(curves)
    }

    /// Running apps using audio, plus apps with rules that aren't running (for the per-app list).
    var perAppList: [AudioApp] {
        var list = audioApps
        for (bundleID, _) in appRules where !list.contains(where: { $0.bundleID == bundleID }) {
            list.append(AudioApp(bundleID: bundleID, name: appRuleNames[bundleID] ?? bundleID,
                                 icon: nil, isPlaying: false, isRunning: false))
        }
        return list.sorted { ($0.isRunning ? 0 : 1, $0.name.lowercased()) < ($1.isRunning ? 0 : 1, $1.name.lowercased()) }
    }

    func refreshAudioApps() {
        audioApps = AudioApp.current()
    }

    // MARK: - Per-device presets (any mode)

    /// The device's assignment, or nil if it has none or its preset no longer exists.
    func assignment(forDevice uid: String) -> DeviceAssignment? {
        guard let assignment = deviceAssignments[uid], presetName(for: assignment) != nil else { return nil }
        return assignment
    }

    func presetName(for assignment: DeviceAssignment) -> String? {
        switch assignment.mode {
        case .simple: Preset.simple.first { $0.id == assignment.presetID }?.name
        case .advanced: advancedPresets.first { $0.id == assignment.presetID }?.name
        case .expert: expertPresets.first { $0.id == assignment.presetID }?.name
        }
    }

    /// Remembers the assignment for the device and applies it now if that device is playing.
    func assign(_ assignment: DeviceAssignment?, toDevice uid: String) {
        deviceAssignments[uid] = assignment
        if let data = try? JSONEncoder().encode(deviceAssignments) { defaults.set(data, forKey: Key.deviceAssignmentsV2) }
        if let assignment, currentDevice?.uid == uid { apply(assignment) }
    }

    /// Forgets every device's assignment to a preset that was deleted.
    private func removeAssignments(to assignment: DeviceAssignment) {
        guard deviceAssignments.values.contains(assignment) else { return }
        deviceAssignments = deviceAssignments.filter { $0.value != assignment }
        if let data = try? JSONEncoder().encode(deviceAssignments) { defaults.set(data, forKey: Key.deviceAssignmentsV2) }
    }

    /// Switches to the assignment's mode and applies its preset.
    private func apply(_ assignment: DeviceAssignment) {
        switch assignment.mode {
        case .simple:
            guard let preset = Preset.simple.first(where: { $0.id == assignment.presetID }) else { return }
            mode = .simple
            applySimple(preset)
        case .advanced:
            guard let preset = advancedPresets.first(where: { $0.id == assignment.presetID }) else { return }
            mode = .advanced
            applyAdvanced(preset)
        case .expert:
            guard let preset = expertPresets.first(where: { $0.id == assignment.presetID }) else { return }
            mode = .expert
            applyExpert(preset)
        }
    }

    private func handle(_ newStatus: EQEngine.Status) {
        status = newStatus
        guard case .running(let device) = newStatus, device.uid != lastDeviceUID else { return }
        lastDeviceUID = device.uid
        if let assignment = assignment(forDevice: device.uid) { apply(assignment) }
    }

    // MARK: - System

    func refreshDevices() {
        devices = OutputDeviceCatalog.outputDevices()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        stopMetering()
        engine.shutdown()
        NSApp.terminate(nil)
    }

    /// Called when the app terminates for any other reason (logout, restart).
    func shutdownEngine() { engine.shutdown() }

    // MARK: - Meter (only runs while a view showing it is open)

    @ObservationIgnored private var meterClients = 0

    func startMetering() {
        meterClients += 1
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopMetering() {
        meterClients = max(0, meterClients - 1)
        guard meterClients == 0 else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func tickMeter() {
        tickAnalyzer()
        let peak = engine.takePeak()
        // Map -60...0 dBFS to 0...1, fast attack / slow release.
        let target = peak > 0 ? max(0, 1 + 20 * log10(peak) / 60) : 0
        level = target > level ? target : max(target, level - 0.03)
    }
}
