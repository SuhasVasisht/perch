import AppKit

// Renders the Perch app icon on Apple's macOS icon grid: a 824pt rounded
// square centred in a 1024pt canvas, with the standard soft drop shadow.
// Usage: make-icon <output.png> [size]

@main
enum MakeIcon {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write("usage: make-icon <out.png> [size]\n".data(using: .utf8)!)
            exit(1)
        }
        let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
    }

    /// Continuous-corner rounded square, close to Apple's icon shape.
    static func squircle(_ rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let n = 5.0
        let steps = 720
        for i in 0..<steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
            let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
            let p = NSPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    static func draw() {
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(body)

        // Drop shadow, as on Apple's own icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 24
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Body: a quiet off-white gradient.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
        ])!.draw(in: body, angle: -90)

        // The handle and page in a deep graphite-to-black gradient, with two
        // quieter text lines inside the page.
        let mark = body.insetBy(dx: 168, dy: 168)
        let ink = NSGradient(colors: [
            NSColor(srgbRed: 0.30, green: 0.31, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1),
        ])!
        ink.draw(in: PerchGlyph.path(in: mark, stroke: 56), angle: -90)
        NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1).setFill()
        PerchGlyph.content(in: mark, stroke: 56).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Hairline edge so the white body holds up on light backgrounds.
        NSColor.black.withAlphaComponent(0.06).setStroke()
        shape.lineWidth = 2
        shape.stroke()
    }
}
