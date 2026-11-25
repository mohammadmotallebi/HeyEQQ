import Testing
@testable import HeyEQQCore

@Suite struct EqualizerAPOTests {
    /// Shape of an AutoEQ ParametricEQ.txt.
    let autoEQ = """
    Preamp: -6.4 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.0 dB Q 0.70
    Filter 2: ON PK Fc 186 Hz Gain -2.6 dB Q 0.91
    Filter 3: ON PK Fc 1449 Hz Gain 1.9 dB Q 1.29
    Filter 4: OFF PK Fc 3500 Hz Gain 4.1 dB Q 2.50
    Filter 5: ON HSC Fc 10000 Hz Gain -1.4 dB Q 0.70
    """

    @Test func parsesAutoEQParametricFile() throws {
        let r = try EqualizerAPO.parse(autoEQ)
        #expect(r.curve.preampDB == -6.4)
        #expect(r.curve.bands.count == 5)
        #expect(r.skippedLines.isEmpty && !r.truncated)
        #expect(r.curve.bands[0] == EQBand(type: .lowShelf, frequency: 105, gainDB: 6, q: 0.70))
        #expect(r.curve.bands[1] == EQBand(type: .peak, frequency: 186, gainDB: -2.6, q: 0.91))
        #expect(r.curve.bands[3].isEnabled == false)
        #expect(r.curve.bands[4].type == .highShelf)
    }

    @Test func handlesPassFiltersBandwidthCommentsAndCommaDecimals() throws {
        let r = try EqualizerAPO.parse("""
        # my curve
        Filter: ON HP Fc 30 Hz
        Filter: ON LPQ Fc 15000 Hz Q 0,5
        Filter: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1.0   # one octave
        Filter: ON AP Fc 500 Hz
        """)
        #expect(r.curve.bands.count == 3)
        #expect(r.curve.bands[0].type == .highPass && r.curve.bands[0].q == 0.7071)
        #expect(r.curve.bands[1].q == 0.5)
        #expect(abs(r.curve.bands[2].q - 1.414) < 0.01)
        #expect(r.skippedLines.count == 1) // all-pass unsupported
    }

    @Test func rejectsTextWithoutFilters() {
        #expect(throws: EqualizerAPO.ImportError.self) { try EqualizerAPO.parse("hello world") }
    }

    @Test func truncatesBeyondMaxBands() throws {
        let text = (1...40).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        let r = try EqualizerAPO.parse(text)
        #expect(r.truncated && r.curve.bands.count == EQCurve.maxBands)
    }

    @Test func exportRoundTrips() throws {
        let curve = EQCurve(bands: [
            EQBand(type: .lowShelf, frequency: 105, gainDB: 6, q: 0.7),
            EQBand(type: .peak, frequency: 1500, gainDB: -2.5, q: 1.3, isEnabled: false),
            EQBand(type: .highPass, frequency: 25, q: 0.71),
            EQBand(type: .notch, frequency: 60, q: 8),
            EQBand(type: .highShelf, frequency: 9000, gainDB: 2, q: 0.71),
        ], preampDB: -6.5)
        #expect(try EqualizerAPO.parse(EqualizerAPO.export(curve)).curve == curve)
    }

    @Test func maxBoostFindsPeakOfCurve() {
        let curve = EQCurve(bands: [EQBand(type: .peak, frequency: 1_000, gainDB: 6, q: 1),
                                    EQBand(type: .peak, frequency: 100, gainDB: -3, q: 1)], preampDB: -20)
        #expect(abs(curve.maxBoostDB() - 6) < 0.2)
    }
}
