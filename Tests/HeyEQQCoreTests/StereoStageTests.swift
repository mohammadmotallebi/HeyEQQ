import CoreAudio
import Foundation
import Testing
@testable import HeyEQQCore

/// Runs a stereo interleaved signal (left = 440 Hz sine at 0.25, right = `rightAmplitude` × the same)
/// through the processor and returns the peak of each output channel in the last buffer.
private func stereoPeaks(_ eq: EQProcessor, rightAmplitude: Float = 1, buffers: Int = 40, frames: Int = 512,
                         between: ((Int) -> Void)? = nil) -> (left: Float, right: Float, maxJump: Float) {
    var input = [Float](repeating: 0, count: frames * 2)
    var output = [Float](repeating: 0, count: frames * 2)
    var phase = 0.0
    var left: Float = 0, right: Float = 0, maxJump: Float = 0, last: Float = 0
    for i in 0..<buffers {
        between?(i)
        for f in 0..<frames {
            let s = Float(0.25 * sin(phase)); phase += 2 * .pi * 440 / eq.sampleRate
            input[f * 2] = s; input[f * 2 + 1] = s * rightAmplitude
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
        left = 0; right = 0
        for f in 0..<frames {
            left = max(left, abs(output[f * 2])); right = max(right, abs(output[f * 2 + 1]))
            maxJump = max(maxJump, abs(output[f * 2 + 1] - last)); last = output[f * 2 + 1]
        }
    }
    return (left, right, maxJump)
}

@Suite struct StereoStageTests {
    private func eq() -> EQProcessor { EQProcessor(sampleRate: 48_000, tapChannelCount: 2) }

    @Test func centreBalanceLeavesBothChannelsAlone() {
        let peaks = stereoPeaks(eq())
        #expect(abs(peaks.left - 0.25) < 0.001)
        #expect(abs(peaks.right - 0.25) < 0.001)
    }

    @Test func fullRightBalanceSilencesLeftOnly() {
        let p = eq()
        p.balance.store(1000, ordering: .relaxed)
        let peaks = stereoPeaks(p)
        #expect(peaks.left < 0.0001)
        #expect(abs(peaks.right - 0.25) < 0.001)
    }

    @Test func halfLeftBalanceHalvesRight() {
        let p = eq()
        p.balance.store(-500, ordering: .relaxed)
        let peaks = stereoPeaks(p)
        #expect(abs(peaks.left - 0.25) < 0.001)
        #expect(abs(peaks.right - 0.125) < 0.001)
    }

    @Test func monoSumsLeftAndRight() {
        let p = eq()
        p.mono.store(true, ordering: .relaxed)
        let peaks = stereoPeaks(p, rightAmplitude: 0) // left only in → half level on both sides
        #expect(abs(peaks.left - 0.125) < 0.001)
        #expect(abs(peaks.right - 0.125) < 0.001)
    }

    @Test func balanceAndMonoChangesDoNotClick() {
        let p = eq()
        let steady = stereoPeaks(p).maxJump
        let moved = stereoPeaks(p, between: { i in
            if i == 10 { p.balance.store(-1000, ordering: .relaxed) }
            if i == 20 { p.mono.store(true, ordering: .relaxed); p.balance.store(0, ordering: .relaxed) }
        }).maxJump
        #expect(moved < steady * 1.5)
    }

    @Test func volumeScalesOutputEvenWhenBypassed() {
        let p = eq()
        p.volume.store(500, ordering: .relaxed)
        #expect(abs(stereoPeaks(p).left - 0.125) < 0.001)
        p.bypass.store(true, ordering: .relaxed)
        #expect(abs(stereoPeaks(p).left - 0.125) < 0.001)
        p.volume.store(0, ordering: .relaxed)
        #expect(stereoPeaks(p).left < 0.0001)
    }

    @Test func volumeChangeDoesNotClick() {
        let p = eq()
        let steady = stereoPeaks(p).maxJump
        let moved = stereoPeaks(p, between: { i in if i == 10 { p.volume.store(200, ordering: .relaxed) } }).maxJump
        #expect(moved < steady * 1.5)
    }

    @Test func bypassIgnoresBalanceAndMono() {
        let p = eq()
        p.balance.store(1000, ordering: .relaxed)
        p.mono.store(true, ordering: .relaxed)
        p.bypass.store(true, ordering: .relaxed)
        let peaks = stereoPeaks(p)
        #expect(abs(peaks.left - 0.25) < 0.001)
    }
}

@Suite struct AutoEQIndexTests {
    private let sample = """
    # Index
    This is a list of all equalization profiles.

    - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
    - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
    - [Sennheiser HD 650](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20650) by crinacle on GRAS 43AG-7
    - [Beyerdynamic DT 770 Pro 80 Ohm](./oratory1990/over-ear/Beyerdynamic%20DT%20770%20Pro%2080%20Ohm) by oratory1990
    """

    @Test func parsesNameSourceRigAndPath() {
        let entries = AutoEQIndex.parse(sample)
        #expect(entries.count == 4)
        #expect(entries[0].name == "1MORE Aero (ANC Off)")
        #expect(entries[0].source == "HypetheSonics")
        #expect(entries[0].rig == "GRAS RA0045")
        #expect(entries[0].path == "HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)")
        #expect(entries[1].rig == nil)
    }

    @Test func buildsParametricEQURL() {
        let entry = AutoEQIndex.parse(sample)[1]
        #expect(entry.parametricEQURL?.absoluteString ==
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/Sennheiser%20HD%20650%20ParametricEQ.txt")
    }

    @Test func searchMatchesAllWordsAndPutsPrefixMatchesFirst() {
        let entries = AutoEQIndex.parse(sample)
        #expect(AutoEQIndex.search(entries, query: "hd 650").count == 2)
        #expect(AutoEQIndex.search(entries, query: "770 beyer").first?.name == "Beyerdynamic DT 770 Pro 80 Ohm")
        #expect(AutoEQIndex.search(entries, query: "  ").isEmpty)
        #expect(AutoEQIndex.search(entries, query: "akg").isEmpty)
    }

    @Test func deviceNameQueryDropsOwnerPrefix() {
        #expect(AutoEQIndex.query(forDeviceName: "Sam’s AirPods Pro") == "AirPods Pro")
        #expect(AutoEQIndex.query(forDeviceName: "Sam's WH-1000XM4") == "WH-1000XM4")
        #expect(AutoEQIndex.query(forDeviceName: "MacBook Pro Speakers") == "MacBook Pro Speakers")
    }
}
