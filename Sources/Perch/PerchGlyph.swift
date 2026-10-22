import AppKit

/// The Perch mark: a widget's handle pill sitting above its cropped page.
/// Used by the menu bar icon and by the app icon generator.
enum PerchGlyph {
    /// The handle and page outline as one filled shape, fitted and centred in
    /// `rect`. `stroke` is the outline width; the handle is as tall as it.
    static func path(in rect: NSRect, stroke: CGFloat) -> NSBezierPath {
        let layout = Layout(rect: rect, stroke: stroke)
        let shape = NSBezierPath(roundedRect: layout.page, xRadius: layout.radius, yRadius: layout.radius)
        let inner = layout.page.insetBy(dx: stroke, dy: stroke)
        let innerRadius = max(layout.radius - stroke, 0)
        shape.append(NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius).reversed)
        shape.append(NSBezierPath(roundedRect: layout.handle, xRadius: stroke / 2, yRadius: stroke / 2))
        return shape
    }

    /// Two text lines inside the page, suggesting a post. Icon sizes only.
    static func content(in rect: NSRect, stroke: CGFloat) -> NSBezierPath {
        let layout = Layout(rect: rect, stroke: stroke)
        let inner = layout.page.insetBy(dx: stroke * 1.9, dy: stroke * 1.9)
        let line = stroke * 0.62
        let path = NSBezierPath()
        let rows: [(CGFloat, CGFloat)] = [(0.66, 1.0), (0.30, 0.62)]
        for (position, length) in rows {
            let y = inner.minY + inner.height * position - line / 2
            path.append(NSBezierPath(roundedRect: NSRect(x: inner.minX, y: y, width: inner.width * length, height: line),
                                     xRadius: line / 2, yRadius: line / 2))
        }
        return path
    }

    private struct Layout {
        let page: NSRect, handle: NSRect, radius: CGFloat

        // Proportions in page-width units: a 1.0 × 0.78 page with a 0.44 wide
        // handle floating just above it.
        init(rect: NSRect, stroke: CGFloat) {
            let gap = stroke * 0.8
            let width = min(rect.width, (rect.height - stroke - gap) / 0.78)
            let height = width * 0.78
            let bottom = rect.midY - (height + gap + stroke) / 2
            page = NSRect(x: rect.midX - width / 2, y: bottom, width: width, height: height)
            handle = NSRect(x: rect.midX - width * 0.22, y: page.maxY + gap, width: width * 0.44, height: stroke)
            radius = width * 0.17
        }
    }
}

enum StatusIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            PerchGlyph.path(in: rect.insetBy(dx: 2, dy: 2.5), stroke: 1.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
