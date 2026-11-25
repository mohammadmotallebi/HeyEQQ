import HeyEQQCore
import SwiftUI

/// Vertical fader for one EQ band: fills from 0 dB toward the value. Right-click to reset.
struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = .accentColor

    private let thumb: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)

            GeometryReader { geo in
                let travel = geo.size.height - thumb
                let span = range.upperBound - range.lowerBound
                let y = { (v: Double) -> CGFloat in thumb / 2 + CGFloat((range.upperBound - v) / span) * travel }
                let valueY = y(value), zeroY = y(0)

                ZStack(alignment: .top) {
                    Capsule().fill(.quaternary).frame(width: 4)
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 10, height: 1).offset(y: zeroY)
                    Capsule().fill(tint)
                        .frame(width: 4, height: max(1, abs(zeroY - valueY)))
                        .offset(y: min(zeroY, valueY))
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(tint, lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .frame(width: thumb, height: thumb)
                        .offset(y: valueY - thumb / 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = Double((drag.location.y - thumb / 2) / max(travel, 1))
                    value = min(max(range.upperBound - fraction * span, range.lowerBound), range.upperBound)
                })
            }

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 40)
        .contextMenu { Button("Reset \(label) to 0 dB") { value = 0 } }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f decibels", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.5, range.upperBound)
            case .decrement: value = max(value - 0.5, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// Maps between frequency/gain and points in a response plot (20 Hz – 20 kHz log scale).
struct ResponsePlot {
    static let minF = 20.0, maxF = 20_000.0
    let rect: CGRect
    let rangeDB: Double

    init(size: CGSize, rangeDB: Double, showsLabels: Bool) {
        let inset: CGFloat = showsLabels ? 28 : 0
        rect = CGRect(x: inset, y: 8, width: max(size.width - inset - 8, 1),
                      height: max(size.height - (showsLabels ? 26 : 16), 1))
        self.rangeDB = rangeDB
    }

    func x(_ f: Double) -> CGFloat {
        rect.minX + CGFloat(log10(f / Self.minF) / log10(Self.maxF / Self.minF)) * rect.width
    }

    func y(_ db: Double) -> CGFloat {
        rect.midY - CGFloat(min(max(db, -rangeDB), rangeDB) / rangeDB) * rect.height / 2
    }

    func frequency(atX x: CGFloat) -> Double {
        let t = Double((x - rect.minX) / rect.width)
        return Self.minF * pow(Self.maxF / Self.minF, min(max(t, 0), 1))
    }

    func gain(atY y: CGFloat) -> Double {
        let t = Double((rect.midY - y) / (rect.height / 2))
        return min(max(t, -1), 1) * rangeDB
    }
}

/// Distinct colour per band index (Expert mode).
func bandColor(_ index: Int) -> Color {
    let palette: [Color] = [.orange, .pink, .purple, .blue, .teal, .green, .yellow, .red, .indigo, .mint, .cyan, .brown]
    return palette[index % palette.count]
}

/// One analyzer frame: level (dBFS) per log-spaced band.
struct SpectrumFrame: Equatable {
    let frequencies: [Double]
    let levelsDB: [Float]
}

extension EnvironmentValues {
    /// When set, response graphs draw this spectrum behind the EQ curve.
    @Entry var spectrumFrame: SpectrumFrame?
}

/// Frequency-response plot of an EQ curve.
struct ResponseCurveView: View {
    @Environment(\.spectrumFrame) private var spectrum
    let curve: EQCurve
    var rangeDB: Double = 12
    var showsLabels = true
    /// Draws each band's own response as a thin coloured line (Expert mode).
    var showsBandCurves = false
    var selectedBand: Int?

    var body: some View {
        Canvas { ctx, size in
            let plot = ResponsePlot(size: size, rangeDB: rangeDB, showsLabels: showsLabels)
            let r = plot.rect

            // Grid
            let grid = Color.primary.opacity(0.08)
            for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
                var p = Path(); p.move(to: CGPoint(x: plot.x(f), y: r.minY)); p.addLine(to: CGPoint(x: plot.x(f), y: r.maxY))
                ctx.stroke(p, with: .color(grid), lineWidth: 1)
            }
            for db in stride(from: -rangeDB, through: rangeDB, by: rangeDB / 2) {
                var p = Path(); p.move(to: CGPoint(x: r.minX, y: plot.y(db))); p.addLine(to: CGPoint(x: r.maxX, y: plot.y(db)))
                ctx.stroke(p, with: .color(db == 0 ? Color.primary.opacity(0.25) : grid), lineWidth: 1)
            }

            if showsLabels {
                for (f, text) in [(100.0, "100"), (1_000, "1k"), (10_000, "10k")] {
                    ctx.draw(Text(text).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.x(f), y: r.maxY + 10))
                }
                for db in [rangeDB, 0, -rangeDB] {
                    ctx.draw(Text(db == 0 ? "0" : String(format: "%+.0f", db)).font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: r.minX / 2, y: plot.y(db)))
                }
            }

            // Live spectrum (−90…0 dBFS mapped to the full plot height), behind the curves.
            if let spectrum, !spectrum.levelsDB.isEmpty {
                var area = Path()
                area.move(to: CGPoint(x: r.minX, y: r.maxY))
                for (f, db) in zip(spectrum.frequencies, spectrum.levelsDB) {
                    let t = CGFloat(min(max((Double(db) + 90) / 90, 0), 1))
                    area.addLine(to: CGPoint(x: plot.x(f), y: r.maxY - t * r.height))
                }
                area.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.06)]),
                    startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
            }

            let steps = max(Int(r.width / 2), 60)
            func path(_ response: (Double) -> Double) -> Path {
                var line = Path()
                for i in 0...steps {
                    let f = ResponsePlot.minF * pow(ResponsePlot.maxF / ResponsePlot.minF, Double(i) / Double(steps))
                    let point = CGPoint(x: plot.x(f), y: plot.y(response(f)))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                return line
            }

            if showsBandCurves {
                for (i, band) in curve.bands.enumerated() where band.isEnabled {
                    let k = BiquadCoefficients.make(for: band, sampleRate: 48_000)
                    let selected = i == selectedBand
                    ctx.stroke(path { k.magnitudeDB(at: $0, sampleRate: 48_000) },
                               with: .color(bandColor(i).opacity(selected ? 0.9 : 0.35)),
                               lineWidth: selected ? 1.5 : 1)
                }
            }

            // Combined curve
            let line = path { curve.responseDB(at: $0) }
            var fill = line
            fill.addLine(to: CGPoint(x: r.maxX, y: plot.y(0)))
            fill.addLine(to: CGPoint(x: r.minX, y: plot.y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(Color.accentColor.opacity(0.15)))
            ctx.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .accessibilityElement()
        .accessibilityLabel("Frequency response")
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * level)
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Input level")
    }
}

extension EQEngine.Status {
    var text: String {
        switch self {
        case .off: "Off — audio plays normally"
        case .starting: "Starting… click Allow if macOS asks"
        case .running(let device): "Equalizing → \(device.name)"
        case .failed(let message): "Error: \(message)"
        }
    }

    var color: Color {
        switch self {
        case .off: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }
}

/// Short label for a band frequency: 32, 125, 1k, 16k.
func frequencyLabel(_ f: Double) -> String {
    f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))"
}
