import CoreAudio
import Foundation
import Testing
@testable import HeyEQQCore

/// Builds input/output buffer lists in a given layout, runs the processor like the IO proc does,
/// and returns per-channel output.
struct Rig {
    enum Layout { case interleaved, perChannel }

    let inChannels: Int
    let outChannels: Int
    let inLayout: Layout
    let outLayout: Layout
    let frames = 512

    /// `signal(channel, frameIndex)` → input sample. Returns output[channel][frame] of the last buffer,
    /// plus the overall output peak per channel across all buffers.
    func run(_ eq: EQProcessor, buffers: Int = 40,
             signal: (Int, Int) -> Float) -> (last: [[Float]], peak: [Float]) {
        var input = [Float](repeating: 0, count: frames * inChannels)
        var output = [Float](repeating: 0, count: frames * outChannels)
        var peak = [Float](repeating: 0, count: outChannels)
        var last: [[Float]] = []

        for b in 0..<buffers {
            for c in 0..<inChannels {
                for f in 0..<frames { input[index(c, f, inChannels, inLayout)] = signal(c, b * frames + f) }
            }
            input.withUnsafeMutableBufferPointer { inPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    let inList = makeList(inPtr.baseAddress!, channels: inChannels, layout: inLayout)
                    let outList = makeList(outPtr.baseAddress!, channels: outChannels, layout: outLayout)
                    eq.process(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
                    free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer)
                }
            }
            last = (0..<outChannels).map { c in (0..<frames).map { output[index(c, $0, outChannels, outLayout)] } }
            for c in 0..<outChannels { peak[c] = max(peak[c], last[c].map(abs).max()!) }
        }
        return (last, peak)
    }

    private func index(_ c: Int, _ f: Int, _ n: Int, _ layout: Layout) -> Int {
        layout == .interleaved ? f * n + c : c * frames + f
    }

    private func makeList(_ base: UnsafeMutablePointer<Float>, channels: Int, layout: Layout) -> UnsafeMutableAudioBufferListPointer {
        let count = layout == .interleaved ? 1 : channels
        let list = AudioBufferList.allocate(maximumBuffers: count)
        if layout == .interleaved {
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: base)
        } else {
            for c in 0..<channels {
                list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: base + c * frames)
            }
        }
        return list
    }
}

private func rmsDB(_ samples: [Float], reference amplitude: Double) -> Double {
    let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
    return 20 * log10(max(rms, 1e-12) / (amplitude / sqrt(2)))
}

private func sine(_ freq: Double, _ amplitude: Float = 0.25) -> (Int) -> Float {
    { amplitude * Float(sin(2 * .pi * freq * Double($0) / 48_000)) }
}

@Suite struct MultichannelTests {
    private func eq(_ curve: EQCurve, channels: Int) -> EQProcessor {
        EQProcessor(sampleRate: 48_000, tapChannelCount: channels, curve: curve)
    }

    @Test(arguments: [Rig.Layout.interleaved, .perChannel])
    func surround51ChannelsStayDiscreteAndEqualized(layout: Rig.Layout) {
        // A distinct frequency per channel; bass boost should lift only the low ones.
        let freqs: [Double] = [1_000, 1_200, 2_000, 40, 3_000, 5_000] // L R C LFE Ls Rs
        let rig = Rig(inChannels: 6, outChannels: 6, inLayout: layout, outLayout: layout)
        let r = rig.run(eq(.simple([6, 0, 0]), channels: 6)) { c, f in sine(freqs[c])(f) }
        for c in 0..<6 {
            let expected = freqs[c] < 100 ? 6.0 : 0.0
            #expect(abs(rmsDB(r.last[c], reference: 0.25) - expected) < 1, "channel \(c) at \(freqs[c]) Hz")
        }
    }

    @Test func channelsDoNotLeakIntoEachOther() {
        let rig = Rig(inChannels: 8, outChannels: 8, inLayout: .perChannel, outLayout: .interleaved)
        let r = rig.run(eq(.graphic([6, 4, 2, 0, -2, 0, 2, 4, 6, 3]), channels: 8)) { c, f in c == 5 ? sine(500)(f) : 0 }
        for c in 0..<8 where c != 5 { #expect(r.peak[c] == 0, "channel \(c) should be silent") }
        #expect(r.peak[5] > 0.1)
    }

    @Test func stereoOnSurroundDeviceUsesFrontPairOnly() {
        let rig = Rig(inChannels: 2, outChannels: 8, inLayout: .interleaved, outLayout: .perChannel)
        let r = rig.run(eq(.flat, channels: 2)) { _, f in sine(1_000)(f) }
        #expect(abs(rmsDB(r.last[0], reference: 0.25)) < 0.1)
        #expect(abs(rmsDB(r.last[1], reference: 0.25)) < 0.1)
        for c in 2..<8 { #expect(r.peak[c] == 0) }
    }

    @Test func surroundTapOnStereoDeviceKeepsFirstTwo() {
        let rig = Rig(inChannels: 6, outChannels: 2, inLayout: .interleaved, outLayout: .interleaved)
        let r = rig.run(eq(.flat, channels: 6)) { c, f in c < 2 ? sine(1_000)(f) : sine(300, 0.9)(f) }
        #expect(abs(rmsDB(r.last[0], reference: 0.25)) < 0.1 && abs(rmsDB(r.last[1], reference: 0.25)) < 0.1)
    }

    @Test func limiterIsLinkedAcrossChannels() {
        // Only the centre channel is hot; the limiter must turn every channel down by the same amount.
        let rig = Rig(inChannels: 6, outChannels: 6, inLayout: .interleaved, outLayout: .interleaved)
        let r = rig.run(eq(.simple([12, 0, 0]), channels: 6), buffers: 60) { c, f in
            c == 2 ? sine(50, 0.9)(f) : sine(50, 0.2)(f)
        }
        #expect(r.peak.allSatisfy { $0 <= Float(EQProcessor.limiterCeiling) + 1e-4 })
        let ratio = r.peak[0] / r.peak[2]
        #expect(abs(ratio - 0.2 / 0.9) < 0.02) // balance preserved
    }

    @Test func monoTapFeedsFrontPair() {
        let rig = Rig(inChannels: 1, outChannels: 6, inLayout: .interleaved, outLayout: .interleaved)
        let r = rig.run(eq(.flat, channels: 1)) { _, f in sine(1_000)(f) }
        #expect(r.peak[0] > 0.2 && r.peak[1] > 0.2)
        for c in 2..<6 { #expect(r.peak[c] == 0) }
    }
}
