// Generates the app icon (Support/AppIcon.icns) and the menu-bar template icon
// (Support/MenuBarIcon.png, @2x) from the geometry of Support/Icon/equalizer.svg
// (SVG Repo #141491, "equalizer"; viewBox 0 0 297 297).
//   swift scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let support = root.appendingPathComponent("Support")

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Bars (x, y, height) and their colours, straight from the SVG.
let bars: [(x: CGFloat, y: CGFloat, h: CGFloat, c: UInt32)] = [
    (189.75, 75.917, 116, 0x27AE60), (90.75, 108.417, 83.5, 0x27AE60),
    (222.75, 108.417, 83.5, 0xBFF796), (123.75, 59.917, 132, 0xBFF796),
    (156.75, 125.917, 66, 0xBFF796), (57.75, 141.917, 50, 0xBFF796),
]
let barWidth: CGFloat = 16.5
let blockY: CGFloat = 198.75, blockH: CGFloat = 16.333

/// Draws in SVG coordinates (y down) into a context of `size` pixels.
func render(size: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1) // SVG y-down
    draw(ctx)
    return rep
}

func appIcon(size: Int) -> NSBitmapImageRep {
    render(size: size) { ctx in
        let s = CGFloat(size)
        // macOS icon grid: artwork ~80% of the canvas, centred.
        let inset = s * 0.1, scale = (s - 2 * inset) / 297
        ctx.translateBy(x: inset, y: inset)
        ctx.scaleBy(x: scale, y: scale)

        let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 297, height: 297), transform: nil)
        ctx.setFillColor(color(0x345F41)); ctx.addPath(circle); ctx.fillPath()

        // Long shadow (path from the SVG, relative commands resolved), clipped to the circle.
        ctx.saveGState()
        ctx.addPath(circle); ctx.clip()
        let shadow = CGMutablePath()
        shadow.move(to: CGPoint(x: 239.25, y: 108.417))
        shadow.addLine(to: CGPoint(x: 57.75, y: 215.083))
        shadow.addLine(to: CGPoint(x: 139.38, y: 296.713))
        shadow.addCurve(to: CGPoint(x: 148.5, y: 297), control1: CGPoint(x: 142.398, y: 296.896), control2: CGPoint(x: 145.437, y: 297))
        shadow.addCurve(to: CGPoint(x: 296.057, y: 165.224), control1: CGPoint(x: 224.859, y: 297), control2: CGPoint(x: 287.746, y: 239.364))
        shadow.closeSubpath()
        ctx.setFillColor(color(0x2D5036)); ctx.addPath(shadow); ctx.fillPath()
        ctx.restoreGState()

        for b in bars {
            ctx.setFillColor(color(b.c)); ctx.fill(CGRect(x: b.x, y: b.y, width: barWidth, height: b.h))
            ctx.setFillColor(color(0xFFA800)); ctx.fill(CGRect(x: b.x, y: blockY, width: barWidth, height: blockH))
        }
    }
}

/// Monochrome glyph (bars + blocks) for the menu bar; macOS tints template images.
func menuBarIcon(size: Int) -> NSBitmapImageRep {
    render(size: size) { ctx in
        let s = CGFloat(size)
        // Slightly wider bars so they survive the small size.
        let w = barWidth * 1.25, dx = (w - barWidth) / 2
        let glyph = CGRect(x: 57.75 - dx, y: 59.917, width: 239.25 + barWidth - 57.75 + 2 * dx, height: blockY + blockH - 59.917)
        let scale = min(s * 0.94 / glyph.width, s * 0.94 / glyph.height)
        ctx.translateBy(x: (s - glyph.width * scale) / 2, y: (s - glyph.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -glyph.minX, y: -glyph.minY)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for b in bars {
            ctx.fill(CGRect(x: b.x - dx, y: b.y, width: w, height: b.h))
            ctx.fill(CGRect(x: b.x - dx, y: blockY, width: w, height: blockH))
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
