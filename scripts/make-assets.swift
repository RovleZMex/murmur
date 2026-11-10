#!/usr/bin/env swift
// Renders Murmur's artwork: the app icon (.icns) and the README banner.
// Usage: swift scripts/make-assets.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let accent = NSColor(srgbRed: 1.0, green: 0.353, blue: 0.306, alpha: 1)   // #FF5A4E
let ink = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)       // #F5F5F7

func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// The mark: three rounded bars, the middle one in accent. Drawn in a 96×96 design space.
func drawMark(in rect: CGRect, _ c: CGContext) {
    let s = rect.width / 96
    func bar(_ x: CGFloat, _ yTop: CGFloat, _ h: CGFloat, _ color: NSColor) {
        // design space is y-down; CG is y-up
        let r = CGRect(x: rect.minX + x * s, y: rect.minY + (96 - yTop - h) * s, width: 10 * s, height: h * s)
        c.setFillColor(color.cgColor)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
        c.fillPath()
    }
    bar(26, 38, 20, ink)
    bar(43, 24, 48, accent)
    bar(60, 34, 28, ink)
}

/// macOS app icon: squircle body on the standard 1024 grid (824 pt shape, 100 pt margin).
func drawIcon(size: Int, _ c: CGContext) {
    let k = CGFloat(size) / 1024
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    c.addPath(path); c.setFillColor(NSColor.black.cgColor); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(path); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    c.restoreGState()

    // subtle inner rim
    c.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5 * k, dy: 1.5 * k), cornerWidth: 184 * k, cornerHeight: 184 * k, transform: nil))
    c.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    c.setLineWidth(3 * k); c.strokePath()

    drawMark(in: body.insetBy(dx: 30 * k, dy: 30 * k), c)
}

// MARK: App icon (.icns)

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        save(render(px, px) { drawIcon(size: px, $0) }, iconset.appendingPathComponent(name))
    }
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run(); p.waitUntilExit()
save(render(1024, 1024) { drawIcon(size: 1024, $0) }, root.appendingPathComponent("docs/icon.png"))

// MARK: Banner (1280×640 — also the GitHub social preview size)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint, mono: Bool = false) {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: size > 60 ? -1.5 : 0]).draw(at: p)
}

let banner = render(1280, 640) { c in
    c.setFillColor(NSColor(srgbRed: 0.067, green: 0.067, blue: 0.075, alpha: 1).cgColor)
    c.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))

    // mock menu bar strip
    c.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    c.fill(CGRect(x: 0, y: 600, width: 1280, height: 40))
    let pill = CGRect(x: 1062, y: 606, width: 128, height: 28)
    c.addPath(CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil))
    c.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor); c.fillPath()
    c.setFillColor(accent.cgColor)
    c.fillEllipse(in: CGRect(x: pill.minX + 14, y: pill.midY - 6, width: 12, height: 12))
    text("12:34", size: 17, weight: .medium, color: ink, at: CGPoint(x: pill.minX + 36, y: pill.minY + 4), mono: true)
    text("10:30 AM", size: 15, weight: .medium, color: ink.withAlphaComponent(0.7), at: CGPoint(x: 1200, y: 611))

    // icon + wordmark
    let iconRep = render(300, 300) { drawIcon(size: 300, $0) }
    c.draw(iconRep.cgImage!, in: CGRect(x: 120, y: 160, width: 300, height: 300))
    text("Murmur", size: 112, weight: .semibold, color: ink, at: CGPoint(x: 450, y: 316))
    text("Record your Mac and your mic.", size: 36, weight: .regular, color: ink.withAlphaComponent(0.85), at: CGPoint(x: 456, y: 262))
    text("Get a transcript. Entirely on-device.", size: 36, weight: .regular, color: ink.withAlphaComponent(0.55), at: CGPoint(x: 456, y: 216))
}
save(banner, root.appendingPathComponent("docs/banner.png"))
print("Wrote Resources/AppIcon.icns, docs/icon.png, docs/banner.png")
