import CoreAudio
import Foundation
import Synchronization

/// Real-time N-band EQ (up to `EQCurve.maxBands`) with preamp, bypass crossfade and a peak limiter.
///
/// The control side publishes a whole `EQCurve` under a mutex; the audio thread only ever *tries*
/// the lock (never blocks) and copies changed bands into preallocated storage. Gains and preamp
/// glide toward their targets; coefficients are interpolated per sample, so changes don't click.
/// No allocation on the audio thread.
public final class EQProcessor: @unchecked Sendable {
    public static let maxBands = EQCurve.maxBands
    /// How fast gains glide toward a new value.
    static let gainSlewDBPerSecond = 60.0
    /// Bypass crossfade duration.
    static let bypassFadeSeconds = 0.015
    /// Peak limiter ceiling (-0.2 dBFS) and release time. Boosts make audio louder; the limiter only
    /// turns it down momentarily when a peak would clip, instead of a fixed worst-case preamp.
    public static let limiterCeiling = 0.977
    static let limiterReleaseSeconds = 0.15

    public let sampleRate: Double
    public let tapChannelCount: Int

    private struct Params {
        var curve: EQCurve
        var version: Int
    }
    private let params: Mutex<Params>

    /// When true, output crossfades to the unprocessed signal.
    public let bypass = Atomic<Bool>(false)
    /// Peak input level * 1000 since last `exchange(0)`, for the meter.
    public let inputPeak = Atomic<Int>(0)

    // Diagnostics, written by the audio thread, read by the engine's logger.
    public let callbackCount = Atomic<Int>(0)
    /// Peak tap input / processed output * 1000 since last `exchange(0)`.
    public let diagInputPeak = Atomic<Int>(0)
    public let diagOutputPeak = Atomic<Int>(0)
    /// Buffer layout seen by the last callback: buffers << 16 | total channels.
    public let inputLayout = Atomic<Int>(0)
    public let outputLayout = Atomic<Int>(0)
    /// Deepest limiter gain * 1000 since last `exchange(1000)` (1000 = not limiting).
    public let diagLimiterGain = Atomic<Int>(1000)

    // Spectrum analyzer tap: processed mono output into a ring buffer (only while enabled).
    public static let analyzerCapacity = 8192 // power of two
    public let analyzerEnabled = Atomic<Bool>(false)
    private let analyzerWriteIndex = Atomic<Int>(0)
    private let analyzerRing: UnsafeMutableBufferPointer<Float>

    // Audio-thread-only state, preallocated for maxBands.
    private let target: UnsafeMutableBufferPointer<EQBand>
    private let current: UnsafeMutableBufferPointer<EQBand>
    private let coeffs: UnsafeMutableBufferPointer<BiquadCoefficients>
    private let startCoeffs: UnsafeMutableBufferPointer<BiquadCoefficients>
    private let ramping: UnsafeMutableBufferPointer<Bool>
    private let active: UnsafeMutableBufferPointer<Bool>
    private let states: UnsafeMutableBufferPointer<BiquadState> // [band * 2 + channel]
    private var targetCount = 0
    private var currentCount = 0
    private var targetPreampDB = 0.0
    private var currentPreampDB = 0.0
    private var seenVersion = -1
    private var limiterGain = 1.0
    private let limiterRelease: Double
    private var wet = 1.0
    private var primed = false

    public init(sampleRate: Double, tapChannelCount: Int, curve: EQCurve = .flat) {
        self.sampleRate = sampleRate
        self.tapChannelCount = tapChannelCount
        limiterRelease = exp(-1 / (Self.limiterReleaseSeconds * sampleRate))
        params = Mutex(Params(curve: curve.sanitized(sampleRate: sampleRate), version: 0))
        let n = Self.maxBands
        let blank = EQBand(type: .peak, frequency: 1_000)
        target = .allocate(capacity: n); target.initialize(repeating: blank)
        current = .allocate(capacity: n); current.initialize(repeating: blank)
        coeffs = .allocate(capacity: n); coeffs.initialize(repeating: .identity)
        startCoeffs = .allocate(capacity: n); startCoeffs.initialize(repeating: .identity)
        ramping = .allocate(capacity: n); ramping.initialize(repeating: false)
        active = .allocate(capacity: n); active.initialize(repeating: false)
        states = .allocate(capacity: n * 2); states.initialize(repeating: .init())
        analyzerRing = .allocate(capacity: Self.analyzerCapacity); analyzerRing.initialize(repeating: 0)
    }

    deinit {
        target.deallocate(); current.deallocate(); coeffs.deallocate(); startCoeffs.deallocate()
        ramping.deallocate(); active.deallocate(); states.deallocate(); analyzerRing.deallocate()
    }

    /// Copies the most recent `buffer.count` analyzer samples (oldest first) into `buffer`, adding
    /// to what's there so several pipelines can be summed. Visualization only: a sample being
    /// written concurrently may be torn, which is harmless here.
    public func addAnalyzerSamples(into buffer: UnsafeMutableBufferPointer<Float>) {
        let count = min(buffer.count, Self.analyzerCapacity)
        let end = analyzerWriteIndex.load(ordering: .acquiring)
        let mask = Self.analyzerCapacity - 1
        for i in 0..<count {
            buffer[i] += analyzerRing[(end - count + i) & mask]
        }
    }

    // MARK: - Control API (any thread)

    public func setCurve(_ curve: EQCurve) {
        let clean = curve.sanitized(sampleRate: sampleRate)
        params.withLock { state in
            guard state.curve != clean else { return }
            state.curve = clean
            state.version += 1
        }
    }

    public var curve: EQCurve { params.withLock { $0.curve } }

    // MARK: - Audio thread

    /// Copies a newly published curve into audio-thread storage, if the lock is free right now.
    private func pullParams() {
        _ = params.withLockIfAvailable { state in
            guard state.version != seenVersion else { return }
            seenVersion = state.version
            let n = min(state.curve.bands.count, Self.maxBands)
            for i in 0..<n { target[i] = state.curve.bands[i] }
            targetCount = n
            targetPreampDB = state.curve.preampDB
        }
    }

    /// True when bands would change shape or disappear, which can't be interpolated directly.
    private func structureDiffers() -> Bool {
        if targetCount < currentCount { return true }
        for i in 0..<currentCount where current[i].type != target[i].type || current[i].isEnabled != target[i].isEnabled {
            return true
        }
        return false
    }

    @inline(__always)
    private func slew(_ value: Double, toward target: Double, maxStep: Double) -> Double {
        let delta = target - value
        return abs(delta) <= maxStep ? target : value + (delta > 0 ? maxStep : -maxStep)
    }

    /// Moves bands toward their targets and refreshes coefficients for this buffer.
    private func advance(frames: Int) {
        let maxStep = Self.gainSlewDBPerSecond * Double(frames) / sampleRate

        // Structural change (e.g. Simple 3-band shelves -> Advanced 10 peaks): glide the old bands to
        // 0 dB, where they're transparent, swap the layout there, then glide the new bands up.
        if primed && structureDiffers() {
            var drained = true
            for i in 0..<currentCount {
                startCoeffs[i] = coeffs[i]
                ramping[i] = false
                var c = current[i]
                guard c.type.usesGain, c.isEnabled, c.gainDB != 0 else { continue }
                c.gainDB = slew(c.gainDB, toward: 0, maxStep: maxStep)
                if c.gainDB != 0 { drained = false }
                current[i] = c
                coeffs[i] = c.isTransparent ? .identity : .make(for: c, sampleRate: sampleRate)
                ramping[i] = true
            }
            if drained {
                for i in 0..<targetCount {
                    current[i] = target[i]
                    if target[i].type.usesGain { current[i].gainDB = 0 }
                    coeffs[i] = current[i].isTransparent ? .identity : .make(for: current[i], sampleRate: sampleRate)
                    states[i * 2] = .init(); states[i * 2 + 1] = .init()
                }
                currentCount = targetCount
            }
            for i in 0..<currentCount {
                if drained { startCoeffs[i] = coeffs[i]; ramping[i] = false }
                active[i] = coeffs[i] != .identity || startCoeffs[i] != .identity
            }
            return
        }

        // New bands start transparent (gain 0) and glide in.
        if targetCount > currentCount {
            for i in currentCount..<targetCount {
                current[i] = target[i]
                if primed && target[i].type.usesGain { current[i].gainDB = 0 }
                coeffs[i] = .identity
                active[i] = false
            }
        }
        currentCount = targetCount

        for i in 0..<currentCount {
            startCoeffs[i] = coeffs[i]
            var c = current[i]
            let t = target[i]
            var changed = !primed
            var snap = !primed

            if c.type != t.type || c.isEnabled != t.isEnabled {
                c.type = t.type; c.isEnabled = t.isEnabled
                changed = true; snap = true // interpolating between different filter shapes isn't meaningful
            }
            if c.frequency != t.frequency || c.q != t.q {
                c.frequency = t.frequency; c.q = t.q
                changed = true
            }
            if c.gainDB != t.gainDB {
                let delta = t.gainDB - c.gainDB
                c.gainDB = (!primed || abs(delta) <= maxStep) ? t.gainDB : c.gainDB + (delta > 0 ? maxStep : -maxStep)
                changed = true
            }

            if changed {
                current[i] = c
                coeffs[i] = c.isTransparent ? .identity : .make(for: c, sampleRate: sampleRate)
                if snap { startCoeffs[i] = coeffs[i] }
            }
            ramping[i] = changed && !snap
            let nowActive = coeffs[i] != .identity || startCoeffs[i] != .identity
            if nowActive && !active[i] { states[i * 2] = .init(); states[i * 2 + 1] = .init() }
            active[i] = nowActive
        }
    }

    /// Pointer + stride for one channel inside an AudioBufferList (handles interleaved or not).
    private struct Channel {
        var ptr: UnsafeMutablePointer<Float>
        var stride: Int
        @inline(__always) subscript(frame: Int) -> Float {
            get { ptr[frame * stride] }
            nonmutating set { ptr[frame * stride] = newValue }
        }
    }

    /// Called from the IO proc. The tap's streams are the last input streams of the aggregate device.
    public func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        // Silence all outputs first; we only fill the first two channels.
        for buf in outList { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbackCount.add(1, ordering: .relaxed)
        inputLayout.store(Self.layout(inList), ordering: .relaxed)
        outputLayout.store(Self.layout(outList), ordering: .relaxed)
        guard let (inL, inR, inFrames) = tapChannels(inList),
              let (outL, outR, outFrames) = firstTwoChannels(outList) else { return }
        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }

        pullParams()
        advance(frames: frames)

        // Preamp glides like band gains.
        let startPreamp = pow(10, currentPreampDB / 20)
        if !primed {
            currentPreampDB = targetPreampDB
        } else if currentPreampDB != targetPreampDB {
            let maxStep = Self.gainSlewDBPerSecond * Double(frames) / sampleRate
            let delta = targetPreampDB - currentPreampDB
            currentPreampDB = abs(delta) <= maxStep ? targetPreampDB : currentPreampDB + (delta > 0 ? maxStep : -maxStep)
        }
        let endPreamp = pow(10, currentPreampDB / 20)
        let preampFrom = primed ? startPreamp : endPreamp
        primed = true

        let bandCount = currentCount
        let wetTarget = bypass.load(ordering: .relaxed) ? 0.0 : 1.0
        let wetStep = 1 / (Self.bypassFadeSeconds * sampleRate)
        let invFrames = 1 / Double(frames)
        var peak: Float = 0
        var outPeak: Float = 0
        var minLimiterGain = limiterGain
        let analyzing = analyzerEnabled.load(ordering: .relaxed)
        let ringStart = analyzerWriteIndex.load(ordering: .relaxed)
        let ringMask = Self.analyzerCapacity - 1

        for f in 0..<frames {
            let xl = inL[f], xr = inR[f]
            peak = max(peak, abs(xl), abs(xr))
            let t = Double(f + 1) * invFrames

            var l = Double(xl), r = Double(xr)
            for b in 0..<bandCount where active[b] {
                let k = ramping[b] ? BiquadCoefficients.lerp(startCoeffs[b], coeffs[b], t) : coeffs[b]
                l = states[b * 2].process(l, k)
                r = states[b * 2 + 1].process(r, k)
            }
            let pre = preampFrom + (endPreamp - preampFrom) * t
            l *= pre; r *= pre

            if wet != wetTarget { wet = wet < wetTarget ? min(wet + wetStep, 1) : max(wet - wetStep, 0) }
            var yl = Double(xl) * (1 - wet) + l * wet
            var yr = Double(xr) * (1 - wet) + r * wet

            // Peak limiter: instant attack (never exceeds the ceiling), smooth exponential release.
            let level = max(abs(yl), abs(yr))
            let needed = level > Self.limiterCeiling ? Self.limiterCeiling / level : 1
            limiterGain = needed < limiterGain ? needed : needed + (limiterGain - needed) * limiterRelease
            minLimiterGain = min(minLimiterGain, limiterGain)
            yl *= limiterGain; yr *= limiterGain

            outL[f] = Float(min(max(yl, -1), 1))
            outR[f] = Float(min(max(yr, -1), 1))
            outPeak = max(outPeak, abs(outL[f]), abs(outR[f]))
            if analyzing { analyzerRing[(ringStart + f) & ringMask] = (outL[f] + outR[f]) * 0.5 }
        }
        if analyzing { analyzerWriteIndex.store(ringStart + frames, ordering: .releasing) }

        let p = Int(peak * 1000)
        if p > inputPeak.load(ordering: .relaxed) { inputPeak.store(p, ordering: .relaxed) }
        if p > diagInputPeak.load(ordering: .relaxed) { diagInputPeak.store(p, ordering: .relaxed) }
        let lg = Int(minLimiterGain * 1000)
        if lg < diagLimiterGain.load(ordering: .relaxed) { diagLimiterGain.store(lg, ordering: .relaxed) }
        let op = Int(outPeak * 1000)
        if op > diagOutputPeak.load(ordering: .relaxed) { diagOutputPeak.store(op, ordering: .relaxed) }
    }

    private static func layout(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var channels = 0
        for buf in list { channels += Int(buf.mNumberChannels) }
        return list.count << 16 | channels
    }

    private func tapChannels(_ list: UnsafeMutableAudioBufferListPointer) -> (Channel, Channel, Int)? {
        // Walk buffers from the end until we've collected the tap's channels.
        var collected = 0
        var startIndex = list.count
        while startIndex > 0 && collected < tapChannelCount {
            startIndex -= 1
            collected += Int(list[startIndex].mNumberChannels)
        }
        guard collected > 0 else { return nil }
        return channels(list, from: startIndex)
    }

    private func firstTwoChannels(_ list: UnsafeMutableAudioBufferListPointer) -> (Channel, Channel, Int)? {
        channels(list, from: 0)
    }

    /// First two channels found in buffers starting at `from`, plus the frame count.
    private func channels(_ list: UnsafeMutableAudioBufferListPointer, from start: Int) -> (Channel, Channel, Int)? {
        var left: Channel?, right: Channel?
        var frames = Int.max
        for i in start..<list.count {
            let buf = list[i]
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self), buf.mNumberChannels > 0 else { continue }
            let n = Int(buf.mNumberChannels)
            frames = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n))
            for c in 0..<n {
                let ch = Channel(ptr: data + c, stride: n)
                if left == nil { left = ch } else if right == nil { right = ch }
            }
            if right != nil { break }
        }
        guard let left, frames != .max else { return nil }
        return (left, right ?? left, frames)
    }
}
