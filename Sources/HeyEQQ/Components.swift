import HeyEQQCore
import SwiftUI

/// Vertical fader for one EQ band: fills from 0 dB toward the value. Right-click to reset.
struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = .accentColor
    /// Narrower fader with smaller text, for the menu-bar popover.
    var compact = false

    private var thumb: CGFloat { compact ? 12 : 16 }

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            Text(String(format: "%+.1f", value))
                .font(compact ? .system(size: 9).monospacedDigit() : .caption2.monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()

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
                .font(compact ? .system(size: 9, weight: .medium) : .caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: compact ? 24 : 40)
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
    /// Recent highest level per band (peak hold); same count as `levelsDB`, or empty.
    var peaksDB: [Float] = []
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
    /// Draws a coloured dot at each band's frequency/gain (read-only; the popover's Expert summary).
    var showsBandMarkers = false

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

            if showsBandMarkers {
                for (i, band) in curve.bands.enumerated() {
                    let center = CGPoint(x: plot.x(band.frequency), y: plot.y(band.type.usesGain ? band.gainDB : 0))
                    let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
                    ctx.opacity = band.isEnabled ? 1 : 0.35
                    ctx.fill(dot, with: .color(bandColor(i)))
                    ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                ctx.opacity = 1
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .accessibilityElement()
        .accessibilityLabel("Frequency response")
    }
}

/// The "sound bar": the live output spectrum as vertical bars, low frequencies on the left.
/// Bars rest as a row of dots when there is no frame (off, or nothing playing).
struct SpectrumBars: View {
    let frame: SpectrumFrame?
    var barCount = 40

    var body: some View {
        Canvas { ctx, size in
            let levels = barLevels()
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount), 1)
            let rest = min(width, 3)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [.accentColor, .cyan, .mint]),
                startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero)
            let peaks = barLevels(frame?.peaksDB ?? [])
            for i in 0..<barCount {
                let x = CGFloat(i) * (width + gap)
                let height = max(rest, levels[i] * size.height)
                let bar = CGRect(x: x, y: size.height - height, width: width, height: height)
                ctx.fill(Path(roundedRect: bar, cornerRadius: min(width / 2, 2)),
                         with: levels[i] > 0 ? shading : .color(Color.primary.opacity(0.18)))
                // Peak-hold cap: a thin line that lingers above the bar, then falls.
                let peakHeight = peaks[i] * size.height
                if peakHeight > height + 3 {
                    ctx.fill(Path(CGRect(x: x, y: size.height - peakHeight, width: width, height: 1.5)),
                             with: .color(Color.primary.opacity(0.55)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live spectrum")
    }

    /// 0...1 per bar: the loudest analyzer band in each bar's slice, −85…−10 dBFS.
    private func barLevels() -> [CGFloat] { barLevels(frame?.levelsDB ?? []) }

    private func barLevels(_ values: [Float]) -> [CGFloat] {
        guard !values.isEmpty else { return Array(repeating: 0, count: barCount) }
        let bands = values.count
        return (0..<barCount).map { i in
            let lo = min(i * bands / barCount, bands - 1)
            let hi = max((i + 1) * bands / barCount, lo + 1)
            let db = values[lo..<min(hi, bands)].max() ?? -100
            return CGFloat(min(max((Double(db) + 85) / 75, 0), 1))
        }
    }
}

extension View {
    /// Rounded, lightly tinted section background used in the popover.
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lights up while the limiter is turning peaks down, with how much. `compact` shows only the dot.
struct LimiterIndicator: View {
    let reductionDB: Double
    var compact = false

    private var active: Bool { reductionDB > 0 }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.orange : Color.primary.opacity(0.18))
                .frame(width: 7, height: 7)
            if !compact {
                Text(active ? String(format: "Limiting −%.1f dB", reductionDB) : "Limiter idle")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active ? Color.orange : Color.secondary)
            }
        }
        .help(active
            ? String(format: "Your boosts push peaks past full scale, so the limiter is turning them down by %.1f dB to prevent distortion. Lower the preamp or the boosts to stop this.", reductionDB)
            : "The limiter only steps in when boosted peaks would clip. Right now it isn't needed.")
        .accessibilityElement()
        .accessibilityLabel(active ? String(format: "Limiter reducing by %.1f decibels", reductionDB) : "Limiter idle")
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

/// Frequency with unit for lists: "80 Hz", "1 kHz", "2.5 kHz".
func frequencyText(_ f: Double) -> String {
    f >= 1_000
        ? (f / 1_000).formatted(.number.precision(.fractionLength(0...2))) + " kHz"
        : f.formatted(.number.precision(.fractionLength(0...1))) + " Hz"
}

/// Short label for a band frequency: 32, 125, 1k, 16k.
func frequencyLabel(_ f: Double) -> String {
    f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))"
}
