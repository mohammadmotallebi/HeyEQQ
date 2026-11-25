import Foundation

/// Biquad coefficients (normalized, a0 == 1). RBJ Audio EQ Cookbook formulas.
public struct BiquadCoefficients: Sendable, Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = BiquadCoefficients()

    public static func make(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        guard band.isEnabled else { return .identity }
        let w0 = 2 * .pi * band.frequency / sampleRate
        let c = cos(w0), s = sin(w0)
        let alpha = s / (2 * band.q)
        let A = pow(10, band.gainDB / 40)

        let b0, b1, b2, a0, a1, a2: Double
        switch band.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
        case .lowShelf:
            let sA = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * c + sA)
            b1 = 2 * A * ((A - 1) - (A + 1) * c)
            b2 = A * ((A + 1) - (A - 1) * c - sA)
            a0 = (A + 1) + (A - 1) * c + sA
            a1 = -2 * ((A - 1) + (A + 1) * c)
            a2 = (A + 1) + (A - 1) * c - sA
        case .highShelf:
            let sA = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * c + sA)
            b1 = -2 * A * ((A - 1) + (A + 1) * c)
            b2 = A * ((A + 1) + (A - 1) * c - sA)
            a0 = (A + 1) - (A - 1) * c + sA
            a1 = 2 * ((A - 1) - (A + 1) * c)
            a2 = (A + 1) - (A - 1) * c - sA
        case .lowPass:
            b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * c; b2 = 1
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .bandPass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        }
        return .init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// |H(e^jw)| in dB at `frequency`.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = b1 * s1 + b2 * s2
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = a1 * s1 + a2 * s2
        let num = numRe * numRe + numIm * numIm
        let den = denRe * denRe + denIm * denIm
        return 10 * log10(max(num, 1e-20) / max(den, 1e-20))
    }

    @inline(__always)
    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self {
        .init(b0: a.b0 + (b.b0 - a.b0) * t, b1: a.b1 + (b.b1 - a.b1) * t, b2: a.b2 + (b.b2 - a.b2) * t,
              a1: a.a1 + (b.a1 - a.a1) * t, a2: a.a2 + (b.a2 - a.a2) * t)
    }
}

/// Transposed Direct Form II state for one channel of one band.
struct BiquadState {
    var z1 = 0.0, z2 = 0.0
    @inline(__always)
    mutating func process(_ x: Double, _ k: BiquadCoefficients) -> Double {
        let y = k.b0 * x + z1
        z1 = k.b1 * x - k.a1 * y + z2
        z2 = k.b2 * x - k.a2 * y
        return y
    }
}
