import CoreAudio
import Foundation
import Testing
@testable import HeyEQQCore

/// Feeds a stereo interleaved sine through EQProcessor the way the IO proc does, returning output RMS (dB)
/// of the final buffer, the max sample-to-sample jump and the max |sample| seen across the whole run.
private func run(_ eq: EQProcessor, freq: Double, amplitude: Double = 0.25, buffers: Int = 40, frames: Int = 512,
                 between: ((Int) -> Void)? = nil) -> (rmsDB: Double, maxJump: Float, hasNaN: Bool, peak: Float) {
    let sr = eq.sampleRate
    var input = [Float](repeating: 0, count: frames * 2)
    var output = [Float](repeating: 0, count: frames * 2)
    var phase = 0.0
    var last: Float = 0
    var maxJump: Float = 0
    var hasNaN = false
    var peak: Float = 0
    var rms = 0.0

    for i in 0..<buffers {
        between?(i)
        for f in 0..<frames {
            let s = Float(amplitude * sin(phase)); phase += 2 * .pi * freq / sr
            input[f * 2] = s; input[f * 2 + 1] = s
        }
        input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                eq.process(input: &inList, output: &outList)
            }
        }
        var sum = 0.0
        for f in 0..<frames {
            let y = output[f * 2]
            if y.isNaN { hasNaN = true }
            peak = max(peak, abs(y))
            maxJump = max(maxJump, abs(y - last)); last = y
            sum += Double(y * y)
        }
        rms = sqrt(sum / Double(frames))
    }
    let inputRMS = amplitude / sqrt(2.0)
    return (20 * log10(rms / inputRMS), maxJump, hasNaN, peak)
}

private func eq(_ curve: EQCurve, sampleRate: Double = 48_000) -> EQProcessor {
    EQProcessor(sampleRate: sampleRate, tapChannelCount: 2, curve: curve)
}

@Suite struct EQProcessorTests {
    @Test func flatIsTransparent() {
        #expect(abs(run(eq(.flat), freq: 1_000).rmsDB) < 0.1)
        #expect(abs(run(eq(.graphic(Array(repeating: 0, count: 10))), freq: 1_000).rmsDB) < 0.1)
    }

    @Test func simpleBassBoostRaisesLowsOnly() {
        let low = run(eq(.simple([6, 0, 0])), freq: 40)
        let high = run(eq(.simple([6, 0, 0])), freq: 5_000)
        // No preamp: boosted lows get louder, highs are untouched (well below the limiter ceiling).
        #expect(abs(low.rmsDB - 6) < 0.8)
        #expect(abs(high.rmsDB) < 0.5)
    }

    @Test func simpleMidAndTrebleAffectTheirRegions() {
        #expect(abs(run(eq(.simple([0, -6, 0]), sampleRate: 44_100), freq: 1_000).rmsDB - -6) < 0.3)
        #expect(abs(run(eq(.simple([0, 0, -6]), sampleRate: 44_100), freq: 16_000).rmsDB - -6) < 0.8)
    }

    @Test func graphicBandHitsItsTarget() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[5] = 6 // 1 kHz
        #expect(abs(run(eq(.graphic(gains)), freq: 1_000).rmsDB - 6) < 0.5)
        #expect(abs(run(eq(.graphic(gains)), freq: 8_000).rmsDB) < 0.5)
    }

    @Test(arguments: [64.0, 250, 1_000, 4_000, 12_000])
    func responseCurveMatchesMeasuredAudio(freq: Double) {
        let curve = EQCurve.graphic([4, -3, 2, 5, -6, 3, -2, 6, -4, 3])
        let measured = run(eq(curve), freq: freq, amplitude: 0.1, buffers: 60).rmsDB
        #expect(abs(measured - curve.responseDB(at: freq)) < 0.5)
    }

    @Test func lowPassAttenuatesHighs() {
        let curve = EQCurve(bands: [EQBand(type: .lowPass, frequency: 1_000, q: 0.7071)])
        #expect(run(eq(curve), freq: 8_000).rmsDB < -30)
        #expect(abs(run(eq(curve), freq: 100).rmsDB) < 0.5)
    }

    @Test func preampApplies() {
        #expect(abs(run(eq(EQCurve(bands: [], preampDB: -6)), freq: 1_000).rmsDB - -6) < 0.1)
    }

    @Test func gainChangesGlideWithoutJumps() {
        let p = eq(.simple([0, 0, 0]))
        // Slam bass from 0 to +12 dB mid-stream; a 0.25-amplitude 100 Hz sine moves at most ~0.0033/sample.
        let r = run(p, freq: 100, buffers: 60) { i in if i == 10 { p.setCurve(.simple([12, 0, 0])) } }
        #expect(!r.hasNaN)
        #expect(r.maxJump < 0.01)
    }

    @Test func switchingSimpleToGraphicStaysStable() {
        let p = eq(.simple([6, 2, 6]))
        let r = run(p, freq: 200, buffers: 80) { i in
            if i == 10 { p.setCurve(.graphic([6, 5, 4, 2, 0, 0, 0, 2, 4, 6])) }
            if i == 40 { p.setCurve(.simple([0, 0, 0])) }
        }
        #expect(!r.hasNaN)
        #expect(r.maxJump < 0.05)
        #expect(abs(r.rmsDB) < 0.3) // back to flat
    }

    @Test func bypassCrossfadesToDrySignal() {
        let p = eq(.simple([0, 0, -12]))
        let r = run(p, freq: 10_000, buffers: 40) { i in if i == 10 { p.bypass.store(true, ordering: .relaxed) } }
        #expect(abs(r.rmsDB) < 0.1)
    }

    @Test func boostingDoesNotLowerUnboostedBands() {
        // Regression: the old worst-case preamp made mids 6 dB quieter when bass + treble were boosted.
        #expect(run(eq(.simple([6, 0, 6])), freq: 1_000).rmsDB > -1.5)
    }

    @Test func limiterPreventsClipping() {
        let r = run(eq(.simple([12, 0, 12])), freq: 50, amplitude: 0.9, buffers: 60)
        #expect(!r.hasNaN)
        #expect(r.peak <= Float(EQProcessor.limiterCeiling) + 1e-4)
    }

    @Test func quietAudioIsNotLimited() {
        let p = eq(.flat)
        _ = run(p, freq: 1_000, amplitude: 0.5)
        #expect(p.diagLimiterGain.load(ordering: .relaxed) == 1000)
    }

    @Test func unsafeValuesAreSanitized() {
        let p = eq(EQCurve(bands: [EQBand(type: .peak, frequency: .nan, gainDB: 40, q: 0)], preampDB: 99))
        let c = p.curve
        #expect(c.bands[0].gainDB == 24 && c.preampDB == 24)
        #expect(c.bands[0].frequency.isFinite && c.bands[0].q >= 0.1)
        #expect(!run(p, freq: 1_000, amplitude: 0.1).hasNaN)
    }
}
