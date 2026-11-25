import Accelerate
import Foundation

/// FFT spectrum for display: Hann-windowed real FFT, grouped into log-spaced bands (20 Hz – 20 kHz),
/// levels in dBFS (a full-scale sine reads ~0 dB) with fast attack / slow release.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let bandFrequencies: [Double]
    /// Smoothed level per band in dBFS, clamped to `floorDB`.
    public private(set) var levelsDB: [Float]
    public static let floorDB: Float = -100

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let bandEdges: [Double]
    private let releaseDBPerFrame: Float

    public init(fftSize: Int = 4096, bandCount: Int = 96, releaseDBPerFrame: Float = 1.5) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        bandEdges = (0...bandCount).map { 20 * pow(1_000, Double($0) / Double(bandCount)) }
        bandFrequencies = (0..<bandCount).map { i in (20 * pow(1_000, (Double(i) + 0.5) / Double(bandCount))) }
        levelsDB = Array(repeating: Self.floorDB, count: bandCount)
        self.releaseDBPerFrame = releaseDBPerFrame
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Analyzes the last `fftSize` samples and updates `levelsDB`.
    @discardableResult
    public func analyze(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= fftSize, sampleRate > 0 else { return levelsDB }
        let input = Array(samples.suffix(fftSize))
        let windowed = vDSP.multiply(input, window)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        power[0] = 0 // DC / Nyquist packing

        // zrip scales by 2 and the Hann window's coherent gain is 0.5, so a sine of amplitude A
        // gives |X| ≈ A·N/2. Convert to amplitude dBFS.
        let reference = Float(fftSize / 2)
        let binHz = sampleRate / Double(fftSize)
        for band in 0..<levelsDB.count {
            var lo = Int((bandEdges[band] / binHz).rounded(.down))
            var hi = Int((bandEdges[band + 1] / binHz).rounded(.up))
            lo = min(max(lo, 1), half - 1)
            hi = min(max(hi, lo + 1), half)
            var peak: Float = 0
            for bin in lo..<hi { peak = max(peak, power[bin]) }
            let db = peak > 0 ? 10 * log10(peak) - 20 * log10(reference) : Self.floorDB
            let level = max(db, Self.floorDB)
            levelsDB[band] = level >= levelsDB[band] ? level : max(level, levelsDB[band] - releaseDBPerFrame)
        }
        return levelsDB
    }

    public func reset() {
        levelsDB = Array(repeating: Self.floorDB, count: levelsDB.count)
    }
}
