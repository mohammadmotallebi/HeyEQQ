// Generates the app icon (Support/AppIcon.icns, Support/Icon/AppIcon-1024.png) and the menu-bar
// template icon (Support/MenuBarIcon.png, @2x). Original HeyEQQ artwork, drawn entirely here:
// five EQ slider tracks with knobs under a smooth response curve, on a rounded square.
//   swift scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let support = root.appendingPathComponent("Support")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Knob heights of the five sliders, 0 (bottom) … 1 (top): a gentle "smile" curve.
let knobs: [CGFloat] = [0.72, 0.45, 0.36, 0.52, 0.80]

/// Draws in a 1000×1000 unit space with y pointing down, into a bitmap of `size` pixels.
func render(size: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 1000, y: -CGFloat(size) / 1000)
    ctx.setShouldAntialias(true)
    draw(ctx)
    return rep
}

/// Slider geometry inside `rect`: x of each track and y of each knob.
func sliderPoints(in rect: CGRect) -> [CGPoint] {
    knobs.enumerated().map { i, k in
        CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(knobs.count - 1),
                y: rect.maxY - rect.height * k)
    }
}

/// Smooth curve through the points (Catmull-Rom converted to cubic Béziers).
func smoothPath(through p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

func appIcon(size: Int) -> NSBitmapImageRep {
    render(size: size) { ctx in
        // macOS icon grid: 824-unit rounded square centred on the 1000 canvas.
        let tile = CGRect(x: 88, y: 88, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

        // Drop shadow under the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(color(0x1B1F4B)); ctx.fillPath()
        ctx.restoreGState()

        // Background: deep indigo to teal, top-left to bottom-right.
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x2B2F7A), color(0x1C6E8C), color(0x19B3A6)] as CFArray,
                            locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 120), end: CGPoint(x: 870, y: 900), options: [])
        // Soft highlight in the upper half.
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 220), startRadius: 0,
                               endCenter: CGPoint(x: 360, y: 220), endRadius: 520, options: [])
        ctx.restoreGState()

        let area = CGRect(x: 250, y: 270, width: 500, height: 460)
        let points = sliderPoints(in: area)

        // Slider tracks.
        ctx.setLineCap(.round)
        ctx.setLineWidth(34)
        ctx.setStrokeColor(color(0xFFFFFF, 0.22))
        for p in points {
            ctx.move(to: CGPoint(x: p.x, y: area.minY)); ctx.addLine(to: CGPoint(x: p.x, y: area.maxY))
        }
        ctx.strokePath()
        // Filled part of each track, below the knob.
        ctx.setStrokeColor(color(0xFFFFFF, 0.55))
        for p in points {
            ctx.move(to: CGPoint(x: p.x, y: p.y)); ctx.addLine(to: CGPoint(x: p.x, y: area.maxY))
        }
        ctx.strokePath()

        // Response curve through the knobs, with a soft glow.
        let curve = smoothPath(through: points)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: color(0xFFD36B, 0.8))
        ctx.addPath(curve)
        ctx.setLineWidth(30); ctx.setLineJoin(.round)
        ctx.setStrokeColor(color(0xFFC94A))
        ctx.strokePath()
        ctx.restoreGState()

        // Knobs.
        for p in points {
            let r: CGFloat = 50
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: color(0x000000, 0.35))
            ctx.setFillColor(color(0xFFFFFF))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            ctx.setFillColor(color(0xFFB627))
            ctx.fillEllipse(in: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40))
        }
    }
}

/// Monochrome glyph for the menu bar (three sliders with knobs); macOS tints template images.
func menuBarIcon(size: Int) -> NSBitmapImageRep {
    render(size: size) { ctx in
        let xs: [CGFloat] = [220, 500, 780]
        let ys: [CGFloat] = [380, 650, 300]
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineCap(.round)
        ctx.setLineWidth(110)
        for x in xs {
            ctx.move(to: CGPoint(x: x, y: 90)); ctx.addLine(to: CGPoint(x: x, y: 910))
        }
        ctx.strokePath()
        // Knobs: punched-out ring so they read at 18 pt.
        for (x, y) in zip(xs, ys) {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: x - 185, y: y - 185, width: 370, height: 370))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: CGRect(x: x - 130, y: y - 130, width: 260, height: 260))
        }
    }
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try write(appIcon(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try write(appIcon(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
try write(appIcon(size: 1024), to: support.appendingPathComponent("Icon/AppIcon-1024.png"))
try write(menuBarIcon(size: 18), to: support.appendingPathComponent("MenuBarIcon.png"))
try write(menuBarIcon(size: 36), to: support.appendingPathComponent("MenuBarIcon@2x.png"))
print("icons written, iconutil status \(iconutil.terminationStatus)")
