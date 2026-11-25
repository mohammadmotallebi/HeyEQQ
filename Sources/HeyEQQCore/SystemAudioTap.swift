import CoreAudio
import Foundation

/// Pipeline: global process tap (muted) -> private aggregate device (tap + real output) -> IO proc runs EQ.
public final class SystemAudioTap {
    /// What the tap captures.
    public enum Target: Equatable, Sendable {
        /// Every process except ourselves and `excluding` (whose audio is handled by other pipelines).
        case global(excluding: [AudioObjectID])
        /// Only these processes (one app's EQ).
        case processes([AudioObjectID])
        /// Multichannel: everything (except us and `excluding`) sent to stream 0 of the output
        /// device, at that stream's full channel count (5.1, 7.1 …) instead of a stereo mixdown.
        case deviceStream(excluding: [AudioObjectID])
        /// Multichannel per-app: these processes' audio sent to stream 0 of the output device.
        case processesOnDevice([AudioObjectID])
    }

    public let outputDevice: OutputDevice
    public let target: Target
    public private(set) var processor: EQProcessor?
    /// False if our own process object couldn't be resolved, so it couldn't be excluded (feedback risk).
    public private(set) var excludedSelf = true

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let initialCurve: EQCurve

    public init(outputDevice: OutputDevice, curve: EQCurve = .flat, target: Target = .global(excluding: [])) {
        self.outputDevice = outputDevice
        self.initialCurve = curve
        self.target = target
    }

    /// Uses the current system default output device.
    public convenience init(curve: EQCurve = .flat) throws {
        guard let device = OutputDeviceCatalog.defaultOutput() else {
            throw CoreAudioError(status: -1, what: "find default output device")
        }
        self.init(outputDevice: device, curve: curve)
    }

    /// Blocks while macOS shows the System Audio Recording permission prompt (first run only).
    public func start() throws {
        do { try startPipeline() } catch { stop(); throw error }
    }

    private func startPipeline() throws {
        // 1. Global stereo tap of every process except ourselves (we play the processed audio, so
        //    tapping ourselves would cause a feedback loop). Muted so the dry signal isn't heard.
        let description: CATapDescription
        switch target {
        case .global(let excluding):
            let ownProcess = try AudioObjectID.processObject(for: getpid())
            excludedSelf = ownProcess != .unknown
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: (excludedSelf ? [ownProcess] : []) + excluding)
        case .processes(let ids):
            // Never includes our own process, so no feedback path.
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .deviceStream(let excluding):
            let ownProcess = try AudioObjectID.processObject(for: getpid())
            excludedSelf = ownProcess != .unknown
            description = CATapDescription(excludingProcesses: (excludedSelf ? [ownProcess] : []) + excluding,
                                           deviceUID: outputDevice.uid, stream: 0)
        case .processesOnDevice(let ids):
            description = CATapDescription(processes: ids, deviceUID: outputDevice.uid, stream: 0)
        }
        description.name = "HeyEQQ Tap"
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        let tapUID = description.uuid.uuidString
        let tapFormat = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError(status: -1, what: "unexpected tap format \(tapFormat)")
        }

        // 2. Private aggregate device: real output device is the clock; tap is an input with drift compensation.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HeyEQQ Aggregate",
            kAudioAggregateDeviceUIDKey: OutputDeviceCatalog.ownAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevice.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        let sampleRate = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, initial: Float64(0)))
            .flatMap { $0 > 0 ? $0 : nil } ?? tapFormat.mSampleRate
        let processor = EQProcessor(sampleRate: sampleRate,
                                    tapChannelCount: Int(tapFormat.mChannelsPerFrame),
                                    curve: initialCurve)
        self.processor = processor

        // 3. IO proc: input = tap audio, output = real device.
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            processor.process(input: input, output: output)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    /// Teardown order: IO proc -> aggregate -> tap. Safe to call more than once.
    public func stop() {
        if aggregateID != .unknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != .unknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    deinit { stop() }
}
