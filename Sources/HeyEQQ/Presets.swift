import Foundation
import HeyEQQCore

/// A named set of gains. Simple presets have 3 gains (bass, mid, treble); Advanced presets have
/// 10 (one per graphic band) plus a preamp. User presets are Advanced presets saved by the user.
struct Preset: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var gains: [Double]
    var preampDB: Double = 0
    var isBuiltIn = true

    // MARK: Simple (bass, mid, treble)

    static let simple: [Preset] = [
        Preset(id: "flat",      name: "Flat",       gains: [0, 0, 0]),
        Preset(id: "bassBoost", name: "Bass Boost", gains: [6, 0, 0]),
        Preset(id: "vocal",     name: "Vocal",      gains: [-2, 4, 1]),
        Preset(id: "treble",    name: "Treble",     gains: [0, 0, 5]),
        Preset(id: "podcast",   name: "Podcast",    gains: [-4, 3, 2]),
        Preset(id: "lateNight", name: "Late Night", gains: [-3, 2, -2]),
        Preset(id: "loudness",  name: "Loudness",   gains: [5, -1, 4]),
    ]

    static let simpleFlat = simple[0]

    // MARK: Advanced (32 Hz … 16 kHz)

    static let advanced: [Preset] = [
        Preset(id: "adv.flat",       name: "Flat",         gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(id: "adv.bassBoost",  name: "Bass Boost",   gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(id: "adv.trebleBoost", name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        Preset(id: "adv.vocal",      name: "Vocal",        gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        Preset(id: "adv.podcast",    name: "Podcast",      gains: [-6, -4, -2, 0, 2, 3, 3, 2, 0, -2]),
        Preset(id: "adv.rock",       name: "Rock",         gains: [4, 3, 2, 0, -1, -1, 1, 2, 3, 4]),
        Preset(id: "adv.pop",        name: "Pop",          gains: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        Preset(id: "adv.electronic", name: "Electronic",   gains: [5, 4, 2, 0, -2, 0, 1, 2, 4, 5]),
        Preset(id: "adv.acoustic",   name: "Acoustic",     gains: [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]),
        Preset(id: "adv.classical",  name: "Classical",    gains: [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]),
        Preset(id: "adv.lateNight",  name: "Late Night",   gains: [-4, -3, -2, 0, 1, 2, 2, 0, -2, -3]),
        Preset(id: "adv.loudness",   name: "Loudness",     gains: [6, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
    ]

    static let advancedFlat = advanced[0]

    var curve: EQCurve {
        gains.count == EQCurve.simpleBandCount ? .simple(gains) : .graphic(gains, preampDB: preampDB)
    }
}

/// A full parametric curve (Expert mode). Built-ins plus user presets / AutoEQ imports.
struct ExpertPreset: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var curve: EQCurve
    var isBuiltIn = true

    static let starter = ExpertPreset(id: "exp.starter", name: "Starter (5 bands)", curve: EQCurve(bands: [
        EQBand(type: .lowShelf, frequency: 80, q: 0.7071),
        EQBand(type: .peak, frequency: 250, q: 1),
        EQBand(type: .peak, frequency: 1_000, q: 1),
        EQBand(type: .peak, frequency: 4_000, q: 1),
        EQBand(type: .highShelf, frequency: 10_000, q: 0.7071),
    ]))

    static let builtIn: [ExpertPreset] = [
        starter,
        ExpertPreset(id: "exp.bassShelf", name: "Warm Bass Shelf", curve: EQCurve(bands: [
            EQBand(type: .highPass, frequency: 20, q: 0.7071),
            EQBand(type: .lowShelf, frequency: 105, gainDB: 6, q: 0.7),
            EQBand(type: .peak, frequency: 250, gainDB: -1.5, q: 1.2),
        ], preampDB: -3)),
        ExpertPreset(id: "exp.vocal", name: "Vocal Clarity", curve: EQCurve(bands: [
            EQBand(type: .highPass, frequency: 80, q: 0.7071),
            EQBand(type: .peak, frequency: 300, gainDB: -2, q: 1),
            EQBand(type: .peak, frequency: 3_000, gainDB: 3, q: 1.2),
            EQBand(type: .highShelf, frequency: 10_000, gainDB: 2, q: 0.7071),
        ])),
        ExpertPreset(id: "exp.speech", name: "Speech / Calls", curve: EQCurve(bands: [
            EQBand(type: .highPass, frequency: 120, q: 0.7071),
            EQBand(type: .peak, frequency: 2_500, gainDB: 4, q: 1),
            EQBand(type: .lowPass, frequency: 12_000, q: 0.7071),
        ])),
        ExpertPreset(id: "exp.humNotch", name: "Hum Removal (50/60 Hz)", curve: EQCurve(bands: [
            EQBand(type: .notch, frequency: 50, q: 8),
            EQBand(type: .notch, frequency: 60, q: 8),
            EQBand(type: .notch, frequency: 100, q: 8),
            EQBand(type: .notch, frequency: 120, q: 8),
        ])),
    ]
}

/// JSON files in ~/Library/Application Support/HeyEQQ/.
enum JSONFileStore {
    private static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyEQQ", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let fileURL = url(name)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("HeyEQQ: failed to save \(name): \(error)")
        }
    }
}

enum UserPresetStore {
    static func load() -> [Preset] { JSONFileStore.load([Preset].self, from: "presets.json") ?? [] }
    static func save(_ presets: [Preset]) { JSONFileStore.save(presets, to: "presets.json") }
}
