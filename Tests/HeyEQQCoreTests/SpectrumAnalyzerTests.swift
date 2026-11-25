import CoreAudio
import Foundation
import Testing
@testable import HeyEQQCore

@Suite struct SpectrumAnalyzerTests {
    private func sine(_ freq: Double, amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * freq * Double($0) / sampleRate)) }
    }

    @Test func sinePeaksInItsBandAtCorrectLevel() {
        let analyzer = SpectrumAnalyzer()
        let levels = analyzer.analyze(sine(1_000, amplitude: 0.5, sampleRate: 48_000, count: 4096), sampleRate: 48_000)
        let peakBand = levels.indices.max { levels[$0] < levels[$1] }!
        let f = analyzer.bandFrequencies[peakBand]
        #expect(f > 900 && f < 1_100)
        #expect(abs(levels[peakBand] - -6) < 1.5) // 0.5 amplitude ≈ -6 dBFS
        // Far away from 1 kHz the level is way down.
        let far = analyzer.bandFrequencies.firstIndex { $0 > 8_000 }!
        #expect(levels[far] < -60)
    }

    @Test func silenceStaysAtFloorAndReleaseIsGradual() {
        let analyzer = SpectrumAnalyzer()
        analyzer.analyze(sine(200, amplitude: 1, sampleRate: 44_100, count: 4096), sampleRate: 44_100)
        let loud = analyzer.levelsDB.max()!
        let after = analyzer.analyze([Float](repeating: 0, count: 4096), sampleRate: 44_100).max()!
        #expect(after < loud && after > loud - 2) // released by ~1.5 dB, not dropped to the floor
    }

    @Test func processorRingCapturesOutputOnlyWhenEnabled() {
        let p = EQProcessor(sampleRate: 48_000, tapChannelCount: 2)
        var input = [Float](repeating: 0.25, count: 1024), output = [Float](repeating: 0, count: 1024)
        func runOnce() {
            input.withUnsafeMutableBytes { i in output.withUnsafeMutableBytes { o in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(i.count), mData: i.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
                p.process(input: &inList, output: &outList)
            } }
        }
        var probe = [Float](repeating: 0, count: 256)
        runOnce()
        probe.withUnsafeMutableBufferPointer { p.addAnalyzerSamples(into: $0) }
        #expect(probe.allSatisfy { $0 == 0 })
        p.analyzerEnabled.store(true, ordering: .relaxed)
        runOnce()
        probe.withUnsafeMutableBufferPointer { p.addAnalyzerSamples(into: $0) }
        #expect(probe.allSatisfy { abs($0 - 0.25) < 0.001 })
    }
}
