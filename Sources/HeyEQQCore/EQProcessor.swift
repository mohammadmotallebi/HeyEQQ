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
    /// Most channels processed per pipeline (7.1.4 = 12, with headroom).
    public static let maxChannels = 16
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
    /// Stereo balance in permille: -1000 = left only, 0 = centre, +1000 = right only.
    /// Applies to the front left/right pair of the processed signal (not while bypassed).
    public let balance = Atomic<Int>(0)
    /// When true, the front left/right pair is summed to mono.
    public let mono = Atomic<Bool>(false)
    /// "Accurate treble": use the matched filter design for high bands (see `BiquadCoefficients.makeMatched`).
    public let accurateTreble = Atomic<Bool>(false)
    /// "Smooth limiter": the limiter looks `lookaheadSeconds` ahead and eases into peaks instead of
    /// clamping them the instant they arrive. Delays the output by that much.
    public let smoothLimiter = Atomic<Bool>(false)
    static let lookaheadSeconds = 0.0015
    /// Output volume in permille (1000 = unchanged, 0 = silent), for per-app volume. Unlike
    /// balance and mono it also applies while bypassed: it is a mixer setting, not part of the EQ.
    public let volume = Atomic<Int>(1000)
    /// Deepest limiter gain * 1000 since last `exchange(1000)`, for the UI's limiter indicator
    /// (1000 = the limiter did nothing).
    public let limiterGainMin = Atomic<Int>(1000)
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
    private let states: UnsafeMutableBufferPointer<BiquadState> // [band * maxChannels + channel]
    private let inChannels: UnsafeMutableBufferPointer<Channel>
    private let outChannels: UnsafeMutableBufferPointer<Channel>
    private let wetScratch: UnsafeMutableBufferPointer<Double>
    private let dryScratch: UnsafeMutableBufferPointer<Double>
    private let placeholderSample: UnsafeMutablePointer<Float>
    private var targetCount = 0
    private var currentCount = 0
    private var targetPreampDB = 0.0
    private var currentPreampDB = 0.0
    private var seenVersion = -1
    private var limiterGain = 1.0
    private let limiterRelease: Double
    private var wet = 1.0
    private var balanceL = 1.0
    private var balanceR = 1.0
    private var monoMix = 0.0
    private var volumeGain = 1.0
    private var matchedDesign = false
    // Look-ahead limiter: a delay line per channel plus the gain each delayed frame needs.
    private let lookahead: Int
    private let lookaheadAttack: Double
    private let delayLine: UnsafeMutableBufferPointer<Double> // [channel * lookahead + index]
    private let neededRing: UnsafeMutableBufferPointer<Double>
    private var delayIndex = 0
    private var windowMin = 1.0
    private var windowMinIndex = 0
    private var lookaheadActive = false
    private var primed = false

    public init(sampleRate: Double, tapChannelCount: Int, curve: EQCurve = .flat) {
        self.sampleRate = sampleRate
        self.tapChannelCount = tapChannelCount
        limiterRelease = exp(-1 / (Self.limiterReleaseSeconds * sampleRate))
        lookahead = max(8, Int(Self.lookaheadSeconds * sampleRate))
        lookaheadAttack = exp(-5 / Double(lookahead)) // within 1% of the target after `lookahead` frames
        delayLine = .allocate(capacity: lookahead * Self.maxChannels); delayLine.initialize(repeating: 0)
        neededRing = .allocate(capacity: lookahead); neededRing.initialize(repeating: 1)
        params = Mutex(Params(curve: curve.sanitized(sampleRate: sampleRate), version: 0))
        let n = Self.maxBands
        let blank = EQBand(type: .peak, frequency: 1_000)
        target = .allocate(capacity: n); target.initialize(repeating: blank)
        current = .allocate(capacity: n); current.initialize(repeating: blank)
        coeffs = .allocate(capacity: n); coeffs.initialize(repeating: .identity)
        startCoeffs = .allocate(capacity: n); startCoeffs.initialize(repeating: .identity)
        ramping = .allocate(capacity: n); ramping.initialize(repeating: false)
        active = .allocate(capacity: n); active.initialize(repeating: false)
        states = .allocate(capacity: n * Self.maxChannels); states.initialize(repeating: .init())
        placeholderSample = .allocate(capacity: 1); placeholderSample.initialize(to: 0)
        inChannels = .allocate(capacity: Self.maxChannels)
        inChannels.initialize(repeating: Channel(ptr: placeholderSample, stride: 0))
        outChannels = .allocate(capacity: Self.maxChannels)
        outChannels.initialize(repeating: Channel(ptr: placeholderSample, stride: 0))
        wetScratch = .allocate(capacity: Self.maxChannels); wetScratch.initialize(repeating: 0)
        dryScratch = .allocate(capacity: Self.maxChannels); dryScratch.initialize(repeating: 0)
        analyzerRing = .allocate(capacity: Self.analyzerCapacity); analyzerRing.initialize(repeating: 0)
    }

    deinit {
        target.deallocate(); current.deallocate(); coeffs.deallocate(); startCoeffs.deallocate()
        ramping.deallocate(); active.deallocate(); states.deallocate(); analyzerRing.deallocate()
        delayLine.deallocate(); neededRing.deallocate()
        inChannels.deallocate(); outChannels.deallocate(); wetScratch.deallocate(); dryScratch.deallocate()
        placeholderSample.deallocate()
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

    @inline(__always)
    private func resetStates(band: Int) {
        for c in 0..<Self.maxChannels { states[band * Self.maxChannels + c] = .init() }
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
                coeffs[i] = c.isTransparent ? .identity : .make(for: c, sampleRate: sampleRate, matched: matchedDesign)
                ramping[i] = true
            }
            if drained {
                for i in 0..<targetCount {
                    current[i] = target[i]
                    if target[i].type.usesGain { current[i].gainDB = 0 }
                    coeffs[i] = current[i].isTransparent ? .identity : .make(for: current[i], sampleRate: sampleRate, matched: matchedDesign)
                    resetStates(band: i)
                }
                currentCount = targetCount
            }
            for i in 0..<currentCount {
                if drained { startCoeffs[i] = coeffs[i]; ramping[i] = false }
                active[i] = coeffs[i] != .identity || startCoeffs[i] != .identity
            }
            return
        }

        // Switching the filter design recomputes every band; the coefficients glide across this buffer.
        let wantMatched = accurateTreble.load(ordering: .relaxed)
        let designChanged = wantMatched != matchedDesign
        matchedDesign = wantMatched

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
            var changed = !primed || designChanged
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
                coeffs[i] = c.isTransparent ? .identity : .make(for: c, sampleRate: sampleRate, matched: matchedDesign)
                if snap { startCoeffs[i] = coeffs[i] }
            }
            ramping[i] = changed && !snap
            let nowActive = coeffs[i] != .identity || startCoeffs[i] != .identity
            if nowActive && !active[i] { resetStates(band: i) }
            active[i] = nowActive
        }
    }

    /// Pointer + stride for one channel inside an AudioBufferList (handles interleaved or not).
    struct Channel {
        var ptr: UnsafeMutablePointer<Float>
        var stride: Int
        @inline(__always) subscript(frame: Int) -> Float {
            get { ptr[frame * stride] }
            nonmutating set { ptr[frame * stride] = newValue }
        }
    }

    /// Called from the IO proc. The tap's streams are the last input streams of the aggregate device.
    ///
    /// Channel mapping: tap channel *n* → device channel *n* (5.1 / 7.1 stay discrete). A mono tap
    /// feeds the first two outputs. Device channels beyond the tap's are left silent, which is what
    /// macOS does when stereo content plays on a surround device.
    public func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buf in outList { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbackCount.add(1, ordering: .relaxed)
        inputLayout.store(Self.layout(inList), ordering: .relaxed)
        outputLayout.store(Self.layout(outList), ordering: .relaxed)

        let (inCount, inFrames) = collectChannels(inList, from: tapStartBuffer(inList), into: inChannels)
        let (outCount, outFrames) = collectChannels(outList, from: 0, into: outChannels)
        guard inCount > 0, outCount > 0 else { return }
        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }

        // Processed channels and where each one reads from.
        let mono = inCount == 1
        let channelCount = mono ? min(2, outCount) : min(inCount, outCount)

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

        // Balance turns the opposite side down; it and the mono mix glide so changes don't click.
        let bal = Double(min(max(balance.load(ordering: .relaxed), -1000), 1000)) / 1000
        let balanceLTarget = bal > 0 ? 1 - bal : 1.0
        let balanceRTarget = bal < 0 ? 1 + bal : 1.0
        let monoTarget = self.mono.load(ordering: .relaxed) ? 1.0 : 0.0
        let volumeTarget = Double(min(max(volume.load(ordering: .relaxed), 0), 1000)) / 1000
        if !primed { balanceL = balanceLTarget; balanceR = balanceRTarget; monoMix = monoTarget; volumeGain = volumeTarget }
        let volumeFrom = volumeGain
        let balanceLFrom = balanceL, balanceRFrom = balanceR
        let stereoStage = channelCount >= 2
            && (monoMix != 0 || monoTarget != 0 || balanceL != 1 || balanceR != 1 || balanceLTarget != 1 || balanceRTarget != 1)
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
        let stride = Self.maxChannels

        // Turning the look-ahead on or off changes the delay, so start it from a clean line.
        let smooth = smoothLimiter.load(ordering: .relaxed)
        if smooth != lookaheadActive {
            lookaheadActive = smooth
            delayLine.update(repeating: 0)
            neededRing.update(repeating: 1)
            delayIndex = 0; windowMin = 1; windowMinIndex = 0
        }
        let lookahead = self.lookahead

        for f in 0..<frames {
            for c in 0..<channelCount {
                let x = inChannels[mono ? 0 : c][f]
                peak = max(peak, abs(x))
                dryScratch[c] = Double(x)
                wetScratch[c] = Double(x)
            }
            let t = Double(f + 1) * invFrames

            for b in 0..<bandCount where active[b] {
                let k = ramping[b] ? BiquadCoefficients.lerp(startCoeffs[b], coeffs[b], t) : coeffs[b]
                let base = b * stride
                for c in 0..<channelCount {
                    wetScratch[c] = states[base + c].process(wetScratch[c], k)
                }
            }
            let pre = preampFrom + (endPreamp - preampFrom) * t
            if wet != wetTarget { wet = wet < wetTarget ? min(wet + wetStep, 1) : max(wet - wetStep, 0) }

            if stereoStage {
                if monoMix != monoTarget {
                    monoMix = monoMix < monoTarget ? min(monoMix + wetStep, 1) : max(monoMix - wetStep, 0)
                }
                let l = wetScratch[0], r = wetScratch[1]
                let mid = (l + r) * 0.5
                wetScratch[0] = (l + (mid - l) * monoMix) * (balanceLFrom + (balanceLTarget - balanceLFrom) * t)
                wetScratch[1] = (r + (mid - r) * monoMix) * (balanceRFrom + (balanceRTarget - balanceRFrom) * t)
            }

            // Mix, then one limiter for all channels so the surround balance never shifts.
            var level = 0.0
            let vol = volumeFrom + (volumeTarget - volumeFrom) * t
            for c in 0..<channelCount {
                let y = (dryScratch[c] * (1 - wet) + wetScratch[c] * pre * wet) * vol
                wetScratch[c] = y
                level = max(level, abs(y))
            }
            let needed = level > Self.limiterCeiling ? Self.limiterCeiling / level : 1
            var gain: Double
            if smooth {
                // This frame goes into the delay line; the frame written `lookahead` frames ago comes out.
                let i = delayIndex
                let neededDelayed = neededRing[i]
                neededRing[i] = needed
                // Lowest gain any frame still in the line needs (sliding minimum).
                if needed <= windowMin {
                    windowMin = needed; windowMinIndex = i
                } else if windowMinIndex == i {
                    windowMin = neededRing[0]; windowMinIndex = 0
                    for k in 1..<lookahead where neededRing[k] < windowMin { windowMin = neededRing[k]; windowMinIndex = k }
                }
                // Ease down ahead of a peak, release slowly after it.
                let target = min(windowMin, neededDelayed)
                limiterGain = target + (limiterGain - target) * (target < limiterGain ? lookaheadAttack : limiterRelease)
                gain = min(limiterGain, neededDelayed) // never above what the outgoing frame needs
                for c in 0..<channelCount {
                    let slot = c * lookahead + i
                    let delayed = delayLine[slot]
                    delayLine[slot] = wetScratch[c]
                    wetScratch[c] = delayed
                }
                delayIndex = i + 1 == lookahead ? 0 : i + 1
            } else {
                limiterGain = needed < limiterGain ? needed : needed + (limiterGain - needed) * limiterRelease
                gain = limiterGain
            }
            minLimiterGain = min(minLimiterGain, gain)

            for c in 0..<channelCount {
                let y = Float(min(max(wetScratch[c] * gain, -1), 1))
                outChannels[c][f] = y
                outPeak = max(outPeak, abs(y))
            }
            if analyzing {
                // Front left/right (or mono) for the spectrum display.
                let l = outChannels[0][f], r = channelCount > 1 ? outChannels[1][f] : l
                analyzerRing[(ringStart + f) & ringMask] = (l + r) * 0.5
            }
        }
        if analyzing { analyzerWriteIndex.store(ringStart + frames, ordering: .releasing) }
        balanceL = balanceLTarget
        balanceR = balanceRTarget
        volumeGain = volumeTarget

        let p = Int(peak * 1000)
        if p > inputPeak.load(ordering: .relaxed) { inputPeak.store(p, ordering: .relaxed) }
        if p > diagInputPeak.load(ordering: .relaxed) { diagInputPeak.store(p, ordering: .relaxed) }
        let lg = Int(minLimiterGain * 1000)
        if lg < diagLimiterGain.load(ordering: .relaxed) { diagLimiterGain.store(lg, ordering: .relaxed) }
        if lg < limiterGainMin.load(ordering: .relaxed) { limiterGainMin.store(lg, ordering: .relaxed) }
        let op = Int(outPeak * 1000)
        if op > diagOutputPeak.load(ordering: .relaxed) { diagOutputPeak.store(op, ordering: .relaxed) }
    }

    private static func layout(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var channels = 0
        for buf in list { channels += Int(buf.mNumberChannels) }
        return list.count << 16 | channels
    }

    /// Index of the first buffer holding the tap's channels (they are the last input streams).
    private func tapStartBuffer(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var collected = 0
        var start = list.count
        while start > 0 && collected < tapChannelCount {
            start -= 1
            collected += Int(list[start].mNumberChannels)
        }
        return start
    }

    /// Fills `dest` with up to `maxChannels` channels from buffers starting at `start`.
    /// Returns the channel count and the smallest frame count among those buffers.
    private func collectChannels(_ list: UnsafeMutableAudioBufferListPointer, from start: Int,
                                 into dest: UnsafeMutableBufferPointer<Channel>) -> (count: Int, frames: Int) {
        var count = 0
        var frames = Int.max
        var i = start
        while i < list.count && count < Self.maxChannels {
            let buf = list[i]
            i += 1
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self), buf.mNumberChannels > 0 else { continue }
            let n = Int(buf.mNumberChannels)
            frames = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n))
            for c in 0..<n where count < Self.maxChannels {
                dest[count] = Channel(ptr: data + c, stride: n)
                count += 1
            }
        }
        return (count, frames == .max ? 0 : frames)
    }
}
