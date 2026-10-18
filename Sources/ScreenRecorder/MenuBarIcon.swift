import AppKit

/// The menu bar icon: a small version of the app icon (a green-to-blue badge with viewfinder corners
/// and a red record dot), with a differently coloured badge and glyph for each state.
@MainActor
enum MenuBarIcon {
    enum Badge: Hashable {
        case idle
        case recording
        case paused
        case selecting(CaptureMode)
        case countdown(Int, CaptureMode)
        case capturing
        case busy
    }

    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [Badge: NSImage] = [:]

    private static let green = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.42, alpha: 1)
    private static let teal = NSColor(srgbRed: 0.10, green: 0.72, blue: 0.78, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.04, green: 0.45, blue: 1.00, alpha: 1)
    private static let red = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
    private static let orange = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)
    private static let gray = NSColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1)

    static func image(_ badge: Badge) -> NSImage {
        if let image = cache[badge] { return image }
        let image = NSImage(size: size, flipped: false) { rect in
            draw(badge, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Screen Recorder"
        cache[badge] = image
        return image
    }

    private static func draw(_ badge: Badge, in rect: NSRect) {
        let tile = rect.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 4.5, yRadius: 4.5)
        gradient(for: badge).draw(in: shape, angle: -45)

        // The same sheen as the app icon, on the top half.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.25), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        switch badge {
        case .idle:
            drawViewfinder(in: tile)
            let center = NSPoint(x: tile.midX, y: tile.midY)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3.4, y: center.y - 3.4, width: 6.8, height: 6.8)).fill()
            red.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2.4, y: center.y - 2.4, width: 4.8, height: 4.8)).fill()
        case .recording:
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: tile.midX - 3.5, y: tile.midY - 3.5, width: 7, height: 7),
                         xRadius: 1.5, yRadius: 1.5).fill()
        case .paused:
            NSColor.white.setFill()
            for x in [tile.midX - 3.5, tile.midX + 1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: tile.midY - 4, width: 2.5, height: 8), xRadius: 1, yRadius: 1).fill()
            }
        case .selecting:
            drawViewfinder(in: tile)
        case .countdown(let value, _):
            let text = NSAttributedString(string: "\(value)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: NSColor.white,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: tile.midX - textSize.width / 2, y: tile.midY - textSize.height / 2))
        case .capturing:
            drawSymbol("camera.fill", in: tile, pointSize: 9)
        case .busy:
            drawSymbol("hourglass", in: tile, pointSize: 9)
        }
    }

    private static func gradient(for badge: Badge) -> NSGradient {
        switch badge {
        case .idle: return NSGradient(colors: [green, teal, blue])!
        case .recording: return NSGradient(colors: [red.blended(withFraction: 0.2, of: .white)!, red])!
        case .paused: return NSGradient(colors: [orange.blended(withFraction: 0.2, of: .white)!, orange])!
        case .selecting(let mode), .countdown(_, let mode): return gradient(for: mode)
        case .capturing: return gradient(for: .screenshot)
        case .busy: return NSGradient(colors: [gray.blended(withFraction: 0.2, of: .white)!, gray])!
        }
    }

    /// Green for Video and blue for Screenshot, matching the mode tiles in the menu.
    private static func gradient(for mode: CaptureMode) -> NSGradient {
        switch mode {
        case .video: NSGradient(colors: [green.blended(withFraction: 0.15, of: .white)!, green, teal])!
        case .screenshot: NSGradient(colors: [teal, blue])!
        }
    }

    private static func drawViewfinder(in tile: NSRect) {
        let frame = tile.insetBy(dx: 3.4, dy: 3.4)
        let arm: CGFloat = 3.2
        let corners = NSBezierPath()
        for (corner, dx, dy) in [
            (NSPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (NSPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
            (NSPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (NSPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
        ] {
            corners.move(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
            corners.line(to: corner)
            corners.line(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
        }
        corners.lineWidth = 1.6
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        NSColor.white.setStroke()
        corners.stroke()
    }

    private static func drawSymbol(_ name: String, in tile: NSRect, pointSize: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}
