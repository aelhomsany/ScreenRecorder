// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// A green-to-blue tile (green = Video, blue = Screenshot) with white viewfinder corners and a red
// record dot. The menu bar icon (MenuBarIcon.swift) is a small version of the same design.
import AppKit

let green = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.42, alpha: 1)
let teal = NSColor(srgbRed: 0.10, green: 0.72, blue: 0.78, alpha: 1)
let blue = NSColor(srgbRed: 0.04, green: 0.45, blue: 1.00, alpha: 1)
let red = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)

/// Draws the icon on a 1024-point canvas (scaled to `pixels`).
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // The tile, with the standard macOS margins and a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    blue.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [green, teal, blue])!.draw(in: shape, angle: -45)

    // A gentle sheen on the top half.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Viewfinder corners.
    let frame = tile.insetBy(dx: 170, dy: 170)
    let arm: CGFloat = 140
    let corners = NSBezierPath()
    for (corner, dx, dy) in [
        (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
        (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
    ] {
        corners.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        corners.line(to: corner)
        corners.line(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    corners.lineWidth = 54
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    NSColor.white.setStroke()
    corners.stroke()

    // The record dot: red with a white ring.
    let center = CGPoint(x: tile.midX, y: tile.midY)
    let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 132, y: center.y - 132, width: 264, height: 264))
    NSColor.white.setFill()
    ring.fill()
    let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 102, y: center.y - 102, width: 204, height: 204))
    NSGradient(colors: [red.blended(withFraction: 0.15, of: .white)!, red])!.draw(in: dot, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(pixels: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
