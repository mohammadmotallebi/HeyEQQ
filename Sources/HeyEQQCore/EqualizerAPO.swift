import Foundation

/// Reads and writes the Equalizer APO parametric format, which AutoEQ publishes as `ParametricEQ.txt`:
///
///     Preamp: -6.2 dB
///     Filter 1: ON LSC Fc 105 Hz Gain 6.0 dB Q 0.70
///     Filter 2: ON PK Fc 180 Hz Gain -2.3 dB Q 0.91
public enum EqualizerAPO {
    public struct ImportResult: Sendable {
        public let curve: EQCurve
        /// Filter lines that were understood but not supported (e.g. all-pass), or malformed.
        public let skippedLines: [String]
        /// More filters than `EQCurve.maxBands`; the extra ones were dropped.
        public let truncated: Bool
    }

    public enum ImportError: Error, LocalizedError {
        case noFilters
        public var errorDescription: String? {
            "No filters found. Expected Equalizer APO / AutoEQ “ParametricEQ” text, e.g. “Filter 1: ON PK Fc 100 Hz Gain 3 dB Q 1.0”."
        }
    }

    private static let typeCodes: [String: FilterType] = [
        "PK": .peak, "PEQ": .peak, "MODAL": .peak,
        "LS": .lowShelf, "LSC": .lowShelf, "LSQ": .lowShelf,
        "HS": .highShelf, "HSC": .highShelf, "HSQ": .highShelf,
        "LP": .lowPass, "LPQ": .lowPass,
        "HP": .highPass, "HPQ": .highPass,
        "NO": .notch,
        "BP": .bandPass,
    ]

    public static func parse(_ text: String) throws -> ImportResult {
        var bands: [EQBand] = []
        var preamp = 0.0
        var skipped: [String] = []
        var filterCount = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)

            if key == "preamp" {
                if let value = tokens.first.flatMap(number) { preamp = value }
                continue
            }
            guard key.hasPrefix("filter") else { continue }
            filterCount += 1
            guard let band = parseFilter(tokens) else { skipped.append(rawLine.trimmingCharacters(in: .whitespaces)); continue }
            bands.append(band)
        }

        guard !bands.isEmpty || filterCount > 0 else { throw ImportError.noFilters }
        let truncated = bands.count > EQCurve.maxBands
        return ImportResult(curve: EQCurve(bands: bands, preampDB: preamp), skippedLines: skipped, truncated: truncated)
    }

    /// `ON PK Fc 105 Hz Gain 6.0 dB Q 0.70` (tokens after "Filter N:").
    private static func parseFilter(_ tokens: [String]) -> EQBand? {
        var i = 0
        var enabled = true
        if i < tokens.count, ["ON", "OFF"].contains(tokens[i].uppercased()) {
            enabled = tokens[i].uppercased() == "ON"
            i += 1
        }
        guard i < tokens.count, let type = typeCodes[tokens[i].uppercased()] else { return nil }
        i += 1

        var frequency: Double?
        var gain = 0.0
        var q: Double?
        while i < tokens.count {
            let token = tokens[i].lowercased()
            let next = i + 1 < tokens.count ? number(tokens[i + 1]) : nil
            switch token {
            case "fc":
                frequency = next; i += 2
            case "gain":
                gain = next ?? 0; i += 2
            case "q":
                q = next; i += 2
            case "bw":
                // "BW Oct 1.0": bandwidth in octaves -> Q
                if i + 2 < tokens.count, tokens[i + 1].lowercased() == "oct", let n = number(tokens[i + 2]), n > 0 {
                    let p = pow(2, n)
                    q = sqrt(p) / (p - 1)
                }
                i += 3
            default:
                i += 1 // units like "Hz", "dB"
            }
        }
        guard let frequency, frequency > 0 else { return nil }
        let defaultQ: Double = switch type {
        case .notch: 5
        case .bandPass, .peak: 1
        default: 0.7071
        }
        return EQBand(type: type, frequency: frequency, gainDB: type.usesGain ? gain : 0,
                      q: q ?? defaultQ, isEnabled: enabled)
    }

    private static func number(_ token: String) -> Double? {
        Double(token.replacingOccurrences(of: ",", with: "."))
    }

    public static func export(_ curve: EQCurve) -> String {
        var lines = [String(format: "Preamp: %.1f dB", curve.preampDB)]
        for (n, band) in curve.bands.enumerated() {
            let state = band.isEnabled ? "ON" : "OFF"
            let fc = String(format: "Fc %g Hz", band.frequency)
            let q = String(format: "Q %.2f", band.q)
            let gain = String(format: "Gain %.1f dB", band.gainDB)
            let body: String = switch band.type {
            case .peak: "PK \(fc) \(gain) \(q)"
            case .lowShelf: "LSC \(fc) \(gain) \(q)"
            case .highShelf: "HSC \(fc) \(gain) \(q)"
            case .lowPass: "LPQ \(fc) \(q)"
            case .highPass: "HPQ \(fc) \(q)"
            case .notch: "NO \(fc) \(q)"
            case .bandPass: "BP \(fc) \(q)"
            }
            lines.append("Filter \(n + 1): \(state) \(body)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
