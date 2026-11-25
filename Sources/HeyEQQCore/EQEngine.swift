import CoreAudio
import Foundation
import os

/// Owns the audio pipelines for the app: starts/stops them, keeps EQ settings across rebuilds,
/// and rebuilds when the output device changes (headphones plugged in, AirPods connect,
/// default output switched, sample rate changed, device removed).
///
/// Per-app EQ: every app with a rule gets its own pipeline (tap of just that app's processes →
/// its own private aggregate → same output device); the main pipeline taps everything else.
/// macOS mixes the pipelines' outputs on the device. If an app pipeline fails to start, that app
/// simply plays unprocessed; sound is never lost.
///
/// All pipeline work happens on a private serial queue. Callbacks are delivered on the main queue.
public final class EQEngine: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case off
        case starting
        case running(device: OutputDevice)
        case failed(String)
    }

    /// Called on the main queue.
    public var onStatusChange: (@Sendable (Status) -> Void)?
    /// Called on the main queue when the set of output devices or the system default changes.
    public var onDevicesChange: (@Sendable () -> Void)?
    /// Called on the main queue when processes start/stop using audio (for the per-app list).
    public var onProcessesChange: (@Sendable () -> Void)?
    /// Called on the main queue with the app bundle IDs currently being equalized separately.
    public var onActiveAppsChange: (@Sendable (Set<String>) -> Void)?

    private let queue = DispatchQueue(label: "com.heyeqq.engine", qos: .userInitiated)
    /// Main processor first, then per-app processors (read by the meter from the main thread).
    private let processors = OSAllocatedUnfairLock<[EQProcessor]>(initialState: [])

    // Queue-confined state.
    private var enabled = false
    private var bypassed = false
    private var analyzerOn = false
    private var curve = EQCurve.flat
    private var appRules: [String: EQCurve] = [:]
    private var preferredUID: String?
    private var mainPipeline: SystemAudioTap?
    private var appPipelines: [String: SystemAudioTap] = [:]
    /// App bundle ID → process objects routed to its pipeline at the last rebuild.
    private var routedProcesses: [String: [AudioObjectID]] = [:]
    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var pendingRebuild: DispatchWorkItem?
    private var pendingProcessCheck: DispatchWorkItem?
    private var diagnosticsTimer: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.heyeqq.app", category: "engine")

    public init() {
        queue.async { self.installSystemListeners() }
    }

    // MARK: - Public control API (any thread)

    public func setEnabled(_ on: Bool) {
        queue.async {
            guard on != self.enabled else { return }
            self.enabled = on
            self.rebuild()
        }
    }

    /// Applies a new main EQ curve; it glides in without clicks.
    public func setCurve(_ newCurve: EQCurve) {
        queue.async {
            self.curve = newCurve
            self.mainPipeline?.processor?.setCurve(newCurve)
        }
    }

    /// Per-app curves keyed by app bundle ID. Apps without a rule use the main curve.
    public func setAppRules(_ rules: [String: EQCurve]) {
        queue.async {
            let appsChanged = Set(rules.keys) != Set(self.appRules.keys)
            self.appRules = rules
            if appsChanged {
                if self.enabled { self.rebuild() }
            } else {
                for (app, pipeline) in self.appPipelines { pipeline.processor?.setCurve(rules[app] ?? .flat) }
            }
        }
    }

    /// A/B comparison: crossfades every pipeline to the unprocessed signal (no rebuild, no gap).
    public func setBypass(_ on: Bool) {
        queue.async {
            self.bypassed = on
            self.log.notice("bypass \(on ? "on" : "off")")
            for p in self.processors.withLock({ $0 }) { p.bypass.store(on, ordering: .relaxed) }
        }
    }

    /// Enables the spectrum-analyzer tap in every pipeline (costs a little CPU; only while visible).
    public func setAnalyzerEnabled(_ on: Bool) {
        queue.async {
            self.analyzerOn = on
            for p in self.processors.withLock({ $0 }) { p.analyzerEnabled.store(on, ordering: .relaxed) }
        }
    }

    /// The most recent processed output (all pipelines summed) for the analyzer, plus its sample rate.
    public func analyzerSamples(count: Int) -> (samples: [Float], sampleRate: Double)? {
        let all = processors.withLock { $0 }
        guard let first = all.first else { return nil }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            for p in all { p.addAnalyzerSamples(into: buffer) }
        }
        return (samples, first.sampleRate)
    }

    /// nil = follow the system default output.
    public func setPreferredOutput(uid: String?) {
        queue.async {
            guard uid != self.preferredUID else { return }
            self.preferredUID = uid
            self.rebuildIfDeviceChanged()
        }
    }

    /// Peak input level (0...1) across all pipelines since the last call.
    public func takePeak() -> Double {
        let all = processors.withLock { $0 }
        let p = all.map { $0.inputPeak.exchange(0, ordering: .relaxed) }.max() ?? 0
        return Double(p) / 1000
    }

    /// Stops processing and restores normal system audio. Waits up to `timeout` seconds.
    public func shutdown(timeout: TimeInterval = 1) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.enabled = false
            self.teardown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Pipeline lifecycle (queue only)

    private func desiredDevice() -> OutputDevice? {
        if let uid = preferredUID, let device = OutputDeviceCatalog.device(uid: uid) { return device }
        return OutputDeviceCatalog.defaultOutput()
    }

    private func teardown() {
        pendingRebuild?.cancel()
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        deviceListeners = []
        processors.withLock { $0 = [] }
        // Apps first so their audio isn't briefly double-handled, then the main pipeline.
        for pipeline in appPipelines.values { pipeline.stop() }
        appPipelines = [:]
        routedProcesses = [:]
        mainPipeline?.stop()
        mainPipeline = nil
        publishActiveApps()
    }

    private func rebuild() {
        teardown()
        guard enabled else { publish(.off); return }
        guard let device = desiredDevice() else { publish(.failed("No output device available")); return }

        // Another HeyEQQ (e.g. the terminal spike) would tap our output and we'd tap theirs: feedback.
        let others = InstanceGuard.otherInstances()
        guard others.isEmpty else {
            let list = others.map(\.description).joined(separator: ", ")
            log.error("not starting, other instance running: \(list, privacy: .public)")
            publish(.failed("Another HeyEQQ is running: \(list). Quit it; HeyEQQ will start automatically."))
            scheduleRebuild(force: true, after: 3)
            return
        }

        publish(.starting)
        let routes = AudioProcessCatalog.processes(for: appRules.keys)
        let excluded = routes.values.flatMap { $0 }

        let main = SystemAudioTap(outputDevice: device, curve: curve, target: .global(excluding: excluded))
        do {
            try main.start() // may block on the first-run permission prompt
        } catch {
            log.error("start failed on \(device.name, privacy: .public): \(String(describing: error), privacy: .public)")
            publish(.failed(String(describing: error)))
            return
        }
        main.processor?.setCurve(curve) // settings may have changed while start() was blocked
        mainPipeline = main
        log.notice("running on \(device.name, privacy: .public) [\(device.uid, privacy: .public)] rate=\(main.processor?.sampleRate ?? 0) excludedSelf=\(main.excludedSelf) appPipelines=\(routes.count)")

        for (app, ids) in routes.sorted(by: { $0.key < $1.key }) {
            let pipeline = SystemAudioTap(outputDevice: device, curve: appRules[app] ?? .flat, target: .processes(ids))
            do {
                try pipeline.start()
                appPipelines[app] = pipeline
                routedProcesses[app] = ids
                log.notice("app pipeline \(app, privacy: .public) processes=\(ids.count)")
            } catch {
                // Its processes are excluded from the main tap but not captured: they play unprocessed.
                log.error("app pipeline \(app, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                routedProcesses[app] = ids
            }
        }

        let active = ([main] + appPipelines.values).compactMap(\.processor)
        for p in active {
            p.bypass.store(bypassed, ordering: .relaxed)
            p.analyzerEnabled.store(analyzerOn, ordering: .relaxed)
        }
        processors.withLock { $0 = active }
        watchActiveDevice(device)
        startDiagnostics()
        publishActiveApps()
        publish(.running(device: device))
    }

    /// Rebuild when processes of ruled apps appear or disappear (app launched, quit, new helper).
    private func checkProcesses() {
        guard enabled, mainPipeline != nil, !appRules.isEmpty else { return }
        let routes = AudioProcessCatalog.processes(for: appRules.keys)
        if routes != routedProcesses {
            log.notice("per-app processes changed; rebuilding")
            rebuild()
        }
    }

    /// Every 0.5 s: feedback guard. Every 2 s: logs callback rate, buffer layout and levels
    /// (`/usr/bin/log stream --predicate 'subsystem == "com.heyeqq.app"'`).
    private func startDiagnostics() {
        var tick = 0, calls = 0, inPeakMax = 0, outPeakMax = 0, limiterMin = 1000, hotWindows = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let p = self.mainPipeline?.processor else { return }
            let inPeak = p.diagInputPeak.exchange(0, ordering: .relaxed)
            calls += p.callbackCount.exchange(0, ordering: .relaxed)
            inPeakMax = max(inPeakMax, inPeak)
            outPeakMax = max(outPeakMax, p.diagOutputPeak.exchange(0, ordering: .relaxed))
            limiterMin = min(limiterMin, p.diagLimiterGain.exchange(1000, ordering: .relaxed))

            // A loop with another system-audio tap drives the input to ~2x full scale and keeps it there;
            // real content doesn't sit that hot for seconds. (App taps can't loop: they never include us.)
            hotWindows = inPeak >= Self.feedbackPeakThreshold ? hotWindows + 1 : 0
            if hotWindows >= Self.feedbackWindows {
                self.log.error("feedback detected (input peak \(inPeak)); stopping")
                self.teardown()
                self.publish(.failed("Feedback detected: another app is capturing system audio. Quit it, then turn HeyEQQ off and on."))
                return
            }

            tick += 1
            if tick % 4 == 0 {
                let inL = p.inputLayout.load(ordering: .relaxed), outL = p.outputLayout.load(ordering: .relaxed)
                self.log.notice("diag main callbacks/2s=\(calls) in=\(inL >> 16)buf/\(inL & 0xFFFF)ch out=\(outL >> 16)buf/\(outL & 0xFFFF)ch inPeak=\(inPeakMax) outPeak=\(outPeakMax) limiterGain=\(limiterMin)")
                for (app, pipeline) in self.appPipelines {
                    guard let ap = pipeline.processor else { continue }
                    self.log.notice("diag app \(app, privacy: .public) callbacks/2s=\(ap.callbackCount.exchange(0, ordering: .relaxed)) inPeak=\(ap.diagInputPeak.exchange(0, ordering: .relaxed)) outPeak=\(ap.diagOutputPeak.exchange(0, ordering: .relaxed))")
                }
                calls = 0; inPeakMax = 0; outPeakMax = 0; limiterMin = 1000
            }
        }
        timer.resume()
        diagnosticsTimer = timer
    }

    /// Input peak (x1000) treated as runaway feedback when sustained.
    static let feedbackPeakThreshold = 1_800
    /// Consecutive 0.5 s windows above the threshold before stopping (2 s).
    static let feedbackWindows = 4

    private func rebuildIfDeviceChanged() {
        guard enabled else { return }
        if mainPipeline?.outputDevice.uid != desiredDevice()?.uid { rebuild() }
    }

    /// Coalesces bursts of Core Audio notifications (a device switch fires several).
    private func scheduleRebuild(force: Bool, after delay: TimeInterval = 0.3) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if force { if self.enabled { self.rebuild() } } else { self.rebuildIfDeviceChanged() }
        }
        pendingRebuild = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func installSystemListeners() {
        let onDevices: () -> Void = { [weak self] in
            guard let self else { return }
            self.scheduleRebuild(force: false)
            if let cb = self.onDevicesChange { DispatchQueue.main.async { cb() } }
        }
        let onProcesses: () -> Void = { [weak self] in
            guard let self else { return }
            self.pendingProcessCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.checkProcesses() }
            self.pendingProcessCheck = work
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
            if let cb = self.onProcessesChange { DispatchQueue.main.async { cb() } }
        }
        systemListeners = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices].compactMap {
            try? PropertyListener(object: .system, selector: $0, queue: queue, handler: onDevices)
        }
        if let listener = try? PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList,
                                                queue: queue, handler: onProcesses) {
            systemListeners.append(listener)
        }
    }

    /// Sample-rate changes need new filter coefficients; a dead device needs a new pipeline.
    private func watchActiveDevice(_ device: OutputDevice) {
        let force: () -> Void = { [weak self] in self?.scheduleRebuild(force: true) }
        deviceListeners = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive].compactMap {
            try? PropertyListener(object: device.id, selector: $0, queue: queue, handler: force)
        }
    }

    private func publish(_ status: Status) {
        guard let cb = onStatusChange else { return }
        DispatchQueue.main.async { cb(status) }
    }

    private func publishActiveApps() {
        guard let cb = onActiveAppsChange else { return }
        let apps = Set(appPipelines.keys)
        DispatchQueue.main.async { cb(apps) }
    }
}
