import CoreAudio
import Foundation
import Testing
@testable import HeyEQQCore

/// Feeds a mono-in-stereo sine through the processor; returns every left-channel output sample.
private func render(_ eq: EQProcessor, freq: Double, amplitude: Double, buffers: Int = 40, frames: Int = 512) -> (input: [Float], output: [Float]) {
    var input = [Float](repeating: 0, count: frames * 2)
    var output = [Float](repeating: 0, count: frames * 2)
    var allIn: [Float] = [], allOut: [Float] = []
    var phase = 0.0
    for _ in 0..<buffers {
        for f in 0..<frames {
            let s = Float(amplitude * sin(phase)); phase += 2 * .pi * freq / eq.sampleRate
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
        for f in 0..<frames { allIn.append(input[f * 2]); allOut.append(output[f * 2]) }
    }
    return (allIn, allOut)
}

private func hasNaN(_ samples: [Float]) -> Bool { samples.contains { $0.isNaN } }
private func maxAbs(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

private func peakDB(_ samples: ArraySlice<Float>, reference: Double) -> Double {
    20 * log10(Double(samples.map { abs($0) }.max() ?? 0) / reference)
}

/// Magnitude (dB) of the analog peaking filter the cookbook and matched designs both approximate.
private func analogPeakDB(at f: Double, centre: Double, gainDB: Double, q: Double) -> Double {
    let x = f / centre, A = pow(10, gainDB / 40)
    let d = (1 - x * x) * (1 - x * x)
    return 10 * log10((d + pow(x * A / q, 2)) / (d + pow(x / (A * q), 2)))
}

@Suite struct AccurateTrebleTests {
    private let fs = 44_100.0

    @Test(arguments: [(8_000.0, 6.0, 1.41), (12_000, 9, 1.0), (16_000, 6, 1.41), (16_000, -6, 1.41), (18_000, 12, 2.0)])
    func matchedPeakFollowsTheAnalogCurveBetterNearTheTop(f: Double, gain: Double, q: Double) {
        let band = EQBand(type: .peak, frequency: f, gainDB: gain, q: q)
        let cookbook = BiquadCoefficients.make(for: band, sampleRate: fs)
        let matched = BiquadCoefficients.make(for: band, sampleRate: fs, matched: true)
        var worstCookbook = 0.0, worstMatched = 0.0
        for probe in stride(from: 1_000.0, through: 20_000, by: 500) {
            let target = analogPeakDB(at: probe, centre: f, gainDB: gain, q: q)
            worstCookbook = max(worstCookbook, abs(cookbook.magnitudeDB(at: probe, sampleRate: fs) - target))
            worstMatched = max(worstMatched, abs(matched.magnitudeDB(at: probe, sampleRate: fs) - target))
        }
        #expect(worstMatched < worstCookbook * 0.6)
        #expect(abs(matched.magnitudeDB(at: f, sampleRate: fs) - gain) < 0.01) // exact at the centre
        #expect(abs(matched.magnitudeDB(at: 20, sampleRate: fs)) < 0.05)       // flat at the bottom
    }

    @Test func matchedFiltersAreStableAndFinite() {
        for type in [FilterType.peak, .lowPass, .highPass, .bandPass] {
            for f in stride(from: 2_500.0, through: 21_000, by: 1_850) {
                for gain in [-24.0, -6, 6, 24] {
                    for q in [0.1, 0.7071, 4, 24] {
                        let k = BiquadCoefficients.make(for: EQBand(type: type, frequency: f, gainDB: gain, q: q),
                                                        sampleRate: fs, matched: true)
                        let finite = k.b0.isFinite && k.b1.isFinite && k.b2.isFinite && k.a1.isFinite && k.a2.isFinite
                        #expect(finite)
                        #expect(abs(k.a2) < 1 && abs(k.a1) < 1 + k.a2, "unstable: \(type) \(f) Hz \(gain) dB Q \(q)")
                    }
                }
            }
        }
    }

    @Test func lowBandsShelvesAndNotchesKeepTheCookbookDesign() {
        let unchanged = [
            EQBand(type: .peak, frequency: 1_000, gainDB: 6, q: 1),
            EQBand(type: .highShelf, frequency: 10_000, gainDB: 6, q: 0.7071),
            EQBand(type: .lowShelf, frequency: 5_000, gainDB: -6, q: 0.7071),
            EQBand(type: .notch, frequency: 8_000, q: 8),
        ]
        for band in unchanged {
            #expect(BiquadCoefficients.make(for: band, sampleRate: fs, matched: true)
                == BiquadCoefficients.make(for: band, sampleRate: fs))
        }
    }

    @Test func aCutUndoesTheSameBoost() {
        let boost = BiquadCoefficients.make(for: EQBand(type: .peak, frequency: 14_000, gainDB: 9, q: 1.2), sampleRate: fs, matched: true)
        let cut = BiquadCoefficients.make(for: EQBand(type: .peak, frequency: 14_000, gainDB: -9, q: 1.2), sampleRate: fs, matched: true)
        for probe in [100.0, 5_000, 14_000, 19_000] {
            #expect(abs(boost.magnitudeDB(at: probe, sampleRate: fs) + cut.magnitudeDB(at: probe, sampleRate: fs)) < 1e-6)
        }
    }

    @Test func processorUsesTheMatchedDesignWhenSwitchedOn() {
        let band = EQBand(type: .peak, frequency: 16_000, gainDB: 6, q: 1.41)
        let expectedMatched = BiquadCoefficients.make(for: band, sampleRate: fs, matched: true).magnitudeDB(at: 19_000, sampleRate: fs)
        let expectedCookbook = BiquadCoefficients.make(for: band, sampleRate: fs).magnitudeDB(at: 19_000, sampleRate: fs)
        #expect(abs(expectedMatched - expectedCookbook) > 0.5) // otherwise this test proves nothing

        let p = EQProcessor(sampleRate: fs, tapChannelCount: 2, curve: EQCurve(bands: [band]))
        #expect(abs(peakDB(render(p, freq: 19_000, amplitude: 0.1).output.suffix(4_096), reference: 0.1) - expectedCookbook) < 0.15)
        p.accurateTreble.store(true, ordering: .relaxed)
        let out = render(p, freq: 19_000, amplitude: 0.1).output
        #expect(!hasNaN(out))
        #expect(abs(peakDB(out.suffix(4_096), reference: 0.1) - expectedMatched) < 0.15)
    }
}

@Suite struct SmoothLimiterTests {
    private func processor(_ curve: EQCurve = .flat) -> EQProcessor {
        let p = EQProcessor(sampleRate: 48_000, tapChannelCount: 2, curve: curve)
        p.smoothLimiter.store(true, ordering: .relaxed)
        return p
    }

    @Test func quietAudioIsOnlyDelayed() {
        let p = processor()
        let delay = Int(EQProcessor.lookaheadSeconds * 48_000)
        let (input, output) = render(p, freq: 440, amplitude: 0.5, buffers: 4)
        #expect(maxAbs(Array(output.prefix(delay))) == 0)
        var worst: Float = 0
        for n in delay..<output.count { worst = max(worst, abs(output[n] - input[n - delay])) }
        #expect(worst < 1e-6)
        #expect(p.limiterGainMin.load(ordering: .relaxed) == 1000)
    }

    @Test func loudBoostedAudioStaysUnderTheCeiling() {
        let p = processor(.simple([12, 0, 12]))
        let out = render(p, freq: 50, amplitude: 0.9, buffers: 60).output
        #expect(!hasNaN(out))
        #expect(maxAbs(out) <= Float(EQProcessor.limiterCeiling) + 1e-4)
        #expect(p.limiterGainMin.load(ordering: .relaxed) < 500)
    }

    @Test func gainComesDownBeforeThePeakInsteadOfAtIt() {
        // A quiet tone that suddenly becomes far too loud. The instant limiter can only react on the
        // loud sample itself; the look-ahead one has already eased the gain down when it arrives.
        func largestStep(smooth: Bool) -> Float {
            let p = EQProcessor(sampleRate: 48_000, tapChannelCount: 2)
            p.smoothLimiter.store(smooth, ordering: .relaxed)
            _ = render(p, freq: 1_000, amplitude: 0.2, buffers: 4)
            let out = render(p, freq: 1_000, amplitude: 3.0, buffers: 4).output
            var step: Float = 0
            for n in 1..<out.count { step = max(step, abs(out[n] - out[n - 1])) }
            return step
        }
        #expect(largestStep(smooth: true) <= largestStep(smooth: false))
    }

    @Test func switchingItOnAndOffMidStreamIsSafe() {
        let p = EQProcessor(sampleRate: 48_000, tapChannelCount: 2, curve: .simple([6, 0, 6]))
        for on in [true, false, true, false] {
            p.smoothLimiter.store(on, ordering: .relaxed)
            let out = render(p, freq: 100, amplitude: 0.9, buffers: 6).output
            #expect(!hasNaN(out))
            #expect(maxAbs(out) <= Float(EQProcessor.limiterCeiling) + 1e-4)
        }
    }
}

@Suite struct SpeakerProtectionTests {
    /// Highest response (bands + preamp) over a frequency range.
    private func peak(_ curve: EQCurve, from lo: Double, to hi: Double) -> Double {
        var best = -Double.infinity
        for i in 0...200 { best = max(best, curve.responseDB(at: lo * pow(hi / lo, Double(i) / 200))) }
        return best
    }

    @Test(arguments: [
        EQCurve.graphic([12, 12, 12, 6, 0, 0, 0, 0, 0, 0]),
        EQCurve.simple([12, 0, 0]),
        EQCurve(bands: [EQBand(type: .lowShelf, frequency: 120, gainDB: 18, q: 0.7071),
                        EQBand(type: .peak, frequency: 60, gainDB: 10, q: 2)]),
    ])
    func bassBoostIsHeldToTheLimit(curve: EQCurve) {
        let safe = curve.speakerSafe()
        #expect(safe.maxBassBoostDB() <= EQCurve.speakerSafeBassBoostDB + 0.1)
        #expect(curve.maxBassBoostDB() > EQCurve.speakerSafeBassBoostDB + 1) // the input really exceeded it
    }

    @Test func nothingEverPlaysLouderThanWithoutTheEQ() {
        for curve in [EQCurve.graphic([12, 12, 6, 0, 0, 0, 0, 4, 8, 12]), .simple([6, 3, 9]),
                      EQCurve.graphic([0, 0, 0, 0, 0, 0, 0, 0, 0, 0], preampDB: 6)] {
            #expect(peak(curve.speakerSafe(), from: 20, to: 20_000) <= 0.001)
        }
    }

    @Test func trebleBoostsKeepTheirShapeAndCutsAreUntouched() {
        let treble = EQCurve.graphic([0, 0, 0, 0, 0, 0, 0, 4, 6, 8])
        #expect(treble.speakerSafe().bands == treble.bands) // only the preamp moves
        let cuts = EQCurve.graphic([-6, -3, 0, 0, 0, 0, 0, 0, -2, -4])
        #expect(cuts.speakerSafe() == cuts)
        #expect(EQCurve.flat.speakerSafe() == EQCurve.flat)
    }
}

@Suite struct ClarityAndHeadroomTests {
    @Test func clarityScalesWithAmountAndIsEmptyAtZero() {
        #expect(EQCurve.clarityBands(amount: 0).isEmpty)
        let full = EQCurve.clarityBands(amount: 1), half = EQCurve.clarityBands(amount: 0.5)
        #expect(full.count == 3)
        for (f, h) in zip(full, half) { #expect(abs(f.gainDB - 2 * h.gainDB) < 1e-9) }
        #expect(full[0].gainDB < 0 && full[1].gainDB > 0 && full[2].gainDB > 0)
    }

    @Test func clarityIsAppendedButNeverExceedsTheBandLimit() {
        let base = EQCurve.graphic(Array(repeating: 2, count: 10))
        #expect(base.addingClarity(1).bands.count == 13)
        #expect(Array(base.addingClarity(1).bands.prefix(10)) == base.bands)
        let fullCurve = EQCurve(bands: Array(repeating: EQBand(type: .peak, frequency: 1_000, gainDB: 1, q: 1), count: EQCurve.maxBands - 1))
        #expect(fullCurve.addingClarity(1).bands.count == EQCurve.maxBands)
    }

    @Test func cleanHeadroomBringsTheHighestPointToZero() {
        let boosted = EQCurve.graphic([6, 4, 0, 0, 0, 0, 0, 0, 3, 5])
        #expect(boosted.headroomNeededDB() > 5)
        let clean = boosted.withCleanHeadroom()
        #expect(clean.bands == boosted.bands)
        #expect(clean.maxBoostDB() + clean.preampDB <= 0)
        #expect(clean.maxBoostDB() + clean.preampDB > -0.11) // no more than needed
    }

    @Test func cleanHeadroomLeavesCurvesThatAlreadyFitAlone() {
        #expect(EQCurve.flat.withCleanHeadroom() == EQCurve.flat)
        let cutOnly = EQCurve.graphic([-3, 0, 0, 0, 0, 0, 0, 0, 0, -2])
        #expect(cutOnly.withCleanHeadroom() == cutOnly)
        let alreadyLowered = EQCurve.graphic([6, 0, 0, 0, 0, 0, 0, 0, 0, 0], preampDB: -9)
        #expect(alreadyLowered.withCleanHeadroom() == alreadyLowered)
    }

    @Test func boostCompensationKeepsThePreampEffective() {
        let boosted = EQCurve.graphic([6, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let boost = boosted.maxBoostDB()
        for preamp in [-9.0, -3, 0, 2.5, 6] {
            var curve = boosted
            curve.preampDB = preamp
            let out = curve.withBoostCompensation()
            #expect(out.bands == curve.bands)
            #expect(abs(out.preampDB - (preamp - boost)) < 0.11)
        }
        #expect(EQCurve.flat.withBoostCompensation() == EQCurve.flat)
        let cutOnly = EQCurve.graphic([-3, 0, 0, 0, 0, 0, 0, 0, 0, -2], preampDB: 4)
        #expect(cutOnly.withBoostCompensation() == cutOnly)
    }
}
