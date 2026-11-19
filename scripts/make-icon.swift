// Draws the app icon and writes an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824 pt body centered in 1024, with a soft drop shadow
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()

    shape.addClip()
    let gradient = NSGradient(colors: [NSColor(red: 1.0, green: 0.56, blue: 0.30, alpha: 1),
                                       NSColor(red: 0.58, green: 0.20, blue: 0.76, alpha: 1),
                                       NSColor(red: 0.13, green: 0.10, blue: 0.38, alpha: 1)],
                              atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: body, angle: -55)

    // soft glass highlight across the top
    let shine = NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)])!
    shine.draw(in: NSBezierPath(ovalIn: CGRect(x: 40 * s, y: 560 * s, width: 944 * s, height: 520 * s)), angle: -90)

    // node wires behind the glyph
    ctx.setLineCap(.round)
    ctx.setLineWidth(22 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    let wire = CGMutablePath()
    wire.move(to: CGPoint(x: 210 * s, y: 300 * s))
    wire.addCurve(to: CGPoint(x: 814 * s, y: 724 * s), control1: CGPoint(x: 560 * s, y: 300 * s), control2: CGPoint(x: 460 * s, y: 724 * s))
    ctx.addPath(wire); ctx.strokePath()
    for p in [CGPoint(x: 210, y: 300), CGPoint(x: 814, y: 724)] {
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: (p.x - 30) * s, y: (p.y - 30) * s, width: 60 * s, height: 60 * s)).fill()
    }

    // the glyph
    let config = NSImage.SymbolConfiguration(pointSize: 430 * s, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let rect = CGRect(x: (1024 * s - tinted.size.width) / 2, y: (1024 * s - tinted.size.height) / 2 - 6 * s,
                          width: tinted.size.width, height: tinted.size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 20 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        tinted.draw(in: rect)
        ctx.restoreGState()
    }

    // inner hairline
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 183 * s, yRadius: 183 * s)
    rim.lineWidth = 3 * s
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(out.path)")
