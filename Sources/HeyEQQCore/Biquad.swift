import Foundation

/// Biquad coefficients (normalized, a0 == 1). RBJ Audio EQ Cookbook formulas.
public struct BiquadCoefficients: Sendable, Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = BiquadCoefficients()

    /// `matched` selects the "accurate treble" design for bands high enough for it to matter.
    public static func make(for band: EQBand, sampleRate: Double, matched: Bool = false) -> BiquadCoefficients {
        guard band.isEnabled else { return .identity }
        if matched, let k = makeMatched(for: band, sampleRate: sampleRate) { return k }
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

    // MARK: Matched design ("accurate treble")

    /// The cookbook formulas squeeze a filter's shape as it approaches half the sample rate, so a
    /// peak at 16 kHz on a 44.1 kHz device comes out narrower and its upper side falls short.
    /// This design (after M. Vicanek, "Matched Second Order Digital Filters") keeps the analog
    /// poles and picks the zeros so the response equals the analog one at DC, at the centre and at
    /// half the sample rate. Used for peak, low-pass, high-pass and band-pass from `sampleRate / 20`
    /// up; below that the cookbook filter is already accurate. Shelves and notches return nil
    /// (the cookbook versions are already right at both ends).
    static func makeMatched(for band: EQBand, sampleRate: Double) -> BiquadCoefficients? {
        guard band.frequency >= sampleRate / 20 else { return nil }
        switch band.type {
        case .peak:
            // A cut is exactly the inverse of the same boost, so design the boost and invert it.
            guard band.gainDB < 0 else { return matchedPrototype(band, sampleRate: sampleRate) }
            var boost = band
            boost.gainDB = -band.gainDB
            guard let k = matchedPrototype(boost, sampleRate: sampleRate), abs(k.b0) > 1e-9 else { return nil }
            return .init(b0: 1 / k.b0, b1: k.a1 / k.b0, b2: k.a2 / k.b0, a1: k.b1 / k.b0, a2: k.b2 / k.b0)
        case .lowPass:
            return band.frequency < sampleRate * 0.42 ? matchedPrototype(band, sampleRate: sampleRate) : nil
        case .highPass, .bandPass:
            return matchedPrototype(band, sampleRate: sampleRate)
        case .lowShelf, .highShelf, .notch:
            return nil
        }
    }

    private static func matchedPrototype(_ band: EQBand, sampleRate: Double) -> BiquadCoefficients? {
        let w0 = 2 * .pi * band.frequency / sampleRate
        let A = pow(10, band.gainDB / 40)
        let Q = band.q
        let type = band.type

        /// |H(jx)|² of the analog prototype, x = frequency / centre frequency.
        func analog(_ x: Double) -> Double {
            let d = (1 - x * x) * (1 - x * x)
            switch type {
            case .peak: return (d + (x * A / Q) * (x * A / Q)) / (d + (x / (A * Q)) * (x / (A * Q)))
            case .lowPass: return 1 / (d + (x / Q) * (x / Q))
            case .highPass: return x * x * x * x / (d + (x / Q) * (x / Q))
            default: return (x / Q) * (x / Q) / (d + (x / Q) * (x / Q)) // band-pass
            }
        }

        // Poles: the analog pole pair sampled directly (impulse invariance).
        let q = 1 / (2 * (type == .peak ? A * Q : Q))
        let a1: Double
        if q <= 1 {
            let angle = (1 - q * q).squareRoot() * w0
            guard angle < 0.98 * .pi else { return nil }
            a1 = -2 * exp(-q * w0) * cos(angle)
        } else {
            a1 = -2 * exp(-q * w0) * cosh((q * q - 1).squareRoot() * w0)
        }
        let a2 = exp(-2 * q * w0)

        // |D|² and |N|² as polynomials in φ1 = sin²(w/2): X0·φ0 + X1·φ1 + X2·4·φ0·φ1.
        let A0 = (1 + a1 + a2) * (1 + a1 + a2), A1 = (1 - a1 + a2) * (1 - a1 + a2), A2 = -4 * a2
        let p1 = sin(w0 / 2) * sin(w0 / 2), p0 = 1 - p1, p2 = 4 * p0 * p1
        let denominatorAtCentre = A0 * p0 + A1 * p1 + A2 * p2

        if type == .highPass {
            // Keep the double zero at DC (12 dB/octave) and match the level at the corner.
            let b0 = (analog(1) * denominatorAtCentre).squareRoot() / (4 * p1)
            guard b0.isFinite else { return nil }
            return .init(b0: b0, b1: -2 * b0, b2: b0, a1: a1, a2: a2)
        }

        let B0 = A0 * analog(0)
        let B1 = A1 * analog(.pi / w0)
        let B2 = (analog(1) * denominatorAtCentre - B0 * p0 - B1 * p1) / p2
        let W = 0.5 * (B0.squareRoot() + B1.squareRoot())
        let inner = W * W + B2
        guard inner >= 0 else { return nil }
        let b0 = 0.5 * (W + inner.squareRoot())
        guard b0 > 1e-12, b0.isFinite else { return nil }
        return .init(b0: b0, b1: 0.5 * (B0.squareRoot() - B1.squareRoot()), b2: -B2 / (4 * b0), a1: a1, a2: a2)
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
