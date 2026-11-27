import Foundation

/// Filter shape of one EQ band.
public enum FilterType: String, Codable, CaseIterable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass

    /// Whether `gainDB` has an effect (otherwise the band is a pure filter).
    public var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }

    public var label: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        case .bandPass: "Band Pass"
        }
    }
}

/// One EQ band. Plain value type (no references) so it can be copied on the audio thread.
public struct EQBand: Codable, Hashable, Sendable {
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(type: FilterType, frequency: Double, gainDB: Double = 0, q: Double = 0.7071, isEnabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    /// True when the band leaves audio unchanged, so it can be skipped.
    var isTransparent: Bool { !isEnabled || (type.usesGain && gainDB == 0) }
}

/// A complete EQ setting: the bands plus an output preamp.
public struct EQCurve: Codable, Hashable, Sendable {
    public static let maxBands = 32
    /// Range offered by the UI sliders.
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let preampRange: ClosedRange<Double> = -12...12

    public var bands: [EQBand]
    public var preampDB: Double

    public init(bands: [EQBand], preampDB: Double = 0) {
        self.bands = Array(bands.prefix(Self.maxBands))
        self.preampDB = preampDB
    }

    public static let flat = EQCurve(bands: [])

    // MARK: Simple mode (3 bands)

    public static let simpleBandCount = 3

    /// Bass 100 Hz low shelf, mid 1 kHz peak, treble 8 kHz high shelf.
    public static func simple(_ gains: [Double], preampDB: Double = 0) -> EQCurve {
        let g = gains + Array(repeating: 0, count: max(0, simpleBandCount - gains.count))
        return EQCurve(bands: [
            EQBand(type: .lowShelf, frequency: 100, gainDB: g[0], q: 0.7071),
            EQBand(type: .peak, frequency: 1_000, gainDB: g[1], q: 0.7),
            EQBand(type: .highShelf, frequency: 8_000, gainDB: g[2], q: 0.7071),
        ], preampDB: preampDB)
    }

    // MARK: Graphic mode (10 bands, ISO octave centres)

    public static let graphicFrequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// One-octave bandwidth.
    public static let graphicQ = 1.41

    public static func graphic(_ gains: [Double], preampDB: Double = 0) -> EQCurve {
        EQCurve(bands: graphicFrequencies.enumerated().map { i, f in
            EQBand(type: .peak, frequency: f, gainDB: i < gains.count ? gains[i] : 0, q: graphicQ)
        }, preampDB: preampDB)
    }

    // MARK: Response

    /// Combined magnitude response in dB at `frequency`, including the preamp.
    public func responseDB(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        var db = preampDB
        for band in bands where !band.isTransparent {
            db += BiquadCoefficients.make(for: band, sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
        return db
    }

    /// Highest boost of the bands alone (preamp excluded) across 20 Hz – 20 kHz.
    /// `-maxBoostDB()` is the preamp that keeps the curve from ever exceeding 0 dB.
    public func maxBoostDB(sampleRate: Double = 48_000) -> Double {
        var bandsOnly = self
        bandsOnly.preampDB = 0
        var best = -Double.infinity
        for i in 0...400 {
            let f = 20 * pow(1_000, Double(i) / 400)
            best = max(best, bandsOnly.responseDB(at: f, sampleRate: sampleRate))
        }
        return best
    }

    // MARK: Sound-quality options

    /// The three bands "Clarity" adds at `amount` 0…1: a low-mid cut, a presence lift and some air.
    public static func clarityBands(amount: Double) -> [EQBand] {
        let k = min(max(amount, 0), 1)
        guard k > 0 else { return [] }
        return [
            EQBand(type: .peak, frequency: 300, gainDB: -2.5 * k, q: 1.0),
            EQBand(type: .peak, frequency: 3_200, gainDB: 3 * k, q: 0.9),
            EQBand(type: .highShelf, frequency: 10_000, gainDB: 4 * k, q: 0.7071),
        ]
    }

    /// This curve with the clarity bands appended (as many as still fit under `maxBands`).
    public func addingClarity(_ amount: Double) -> EQCurve {
        let extra = Self.clarityBands(amount: amount).prefix(max(0, Self.maxBands - bands.count))
        guard !extra.isEmpty else { return self }
        return EQCurve(bands: bands + extra, preampDB: preampDB)
    }

    /// How far the preamp must come down so the curve never rises above 0 dB (0 if it already doesn't).
    public func headroomNeededDB() -> Double {
        max(0, maxBoostDB() + preampDB)
    }

    /// This curve with the preamp lowered by `headroomNeededDB()`, so boosts fit without the limiter.
    public func withCleanHeadroom() -> EQCurve {
        let needed = headroomNeededDB()
        guard needed > 0 else { return self }
        var curve = self
        curve.preampDB = preampDB - (needed * 10).rounded(.up) / 10
        return curve
    }

    /// The "Clean" sound-quality option: the preamp comes down by the bands' highest boost, and the
    /// user's own preamp still applies on top (so the preamp slider always changes the level).
    /// Unlike `withCleanHeadroom()`, a positive preamp can still push peaks into the limiter.
    public func withBoostCompensation() -> EQCurve {
        let boost = max(0, maxBoostDB())
        guard boost > 0 else { return self }
        var curve = self
        curve.preampDB = preampDB - (boost * 10).rounded(.up) / 10
        return curve
    }

    // MARK: Built-in speaker protection

    /// Bass limit used on the Mac's own speakers: below this frequency…
    public static let speakerSafeBassHz = 250.0
    /// …the bands together may boost by at most this much.
    public static let speakerSafeBassBoostDB = 6.0

    /// The version of this curve that is allowed on built-in speakers:
    /// 1. the combined boost below `speakerSafeBassHz` is held to `speakerSafeBassBoostDB`
    ///    (bass boosts are scaled down until it fits), and
    /// 2. the preamp is lowered so no frequency ever plays louder than it would without the EQ.
    public func speakerSafe() -> EQCurve {
        var curve = self
        for _ in 0..<6 {
            let bass = curve.maxBassBoostDB()
            guard bass > Self.speakerSafeBassBoostDB + 0.05 else { break }
            let scale = Self.speakerSafeBassBoostDB / bass
            // Scale every boost that reaches into the bass (bands up to an octave above the limit).
            for i in curve.bands.indices where curve.bands[i].isEnabled && curve.bands[i].type.usesGain
                && curve.bands[i].gainDB > 0 && curve.bands[i].frequency <= Self.speakerSafeBassHz * 2 {
                curve.bands[i].gainDB *= scale
            }
        }
        return curve.withCleanHeadroom()
    }

    /// Highest boost of the bands alone between 20 Hz and `speakerSafeBassHz`.
    func maxBassBoostDB() -> Double {
        var bandsOnly = self
        bandsOnly.preampDB = 0
        var best = -Double.infinity
        for i in 0...60 {
            let f = 20 * pow(Self.speakerSafeBassHz / 20, Double(i) / 60)
            best = max(best, bandsOnly.responseDB(at: f))
        }
        return best
    }

    /// Clamps values to what the DSP can safely run at `sampleRate`.
    func sanitized(sampleRate: Double) -> EQCurve {
        let nyquistLimit = sampleRate * 0.49
        return EQCurve(bands: bands.prefix(Self.maxBands).map { b in
            var b = b
            b.frequency = min(max(b.frequency.isFinite ? b.frequency : 1_000, 10), nyquistLimit)
            b.q = min(max(b.q.isFinite ? b.q : 0.7071, 0.1), 24)
            b.gainDB = min(max(b.gainDB.isFinite ? b.gainDB : 0, -24), 24)
            return b
        }, preampDB: min(max(preampDB.isFinite ? preampDB : 0, -24), 24))
    }
}
