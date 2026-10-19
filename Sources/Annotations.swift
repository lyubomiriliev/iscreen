import AppKit

enum Tool: Int, CaseIterable {
    case select, pen, line, arrow, rectangle, highlighter, text, counter, pixelate

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select / move"
        case .pen: return "Pen"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .highlighter: return "Highlight text"
        case .text: return "Text"
        case .counter: return "Numbered step"
        case .pixelate: return "Pixelate (hide)"
        }
    }

    /// Single-key shortcut while the overlay is open.
    var key: String {
        switch self {
        case .select: return "v"
        case .pen: return "p"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "b"
        }
    }
}

enum StrokeSize: Int, CaseIterable {
    case small, medium, large

    var lineWidth: CGFloat { [2, 4, 7][rawValue] }
    var fontSize: CGFloat { [15, 20, 28][rawValue] }
    var counterDiameter: CGFloat { [20, 26, 34][rawValue] }
    var title: String { ["Small", "Medium", "Large"][rawValue] }
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1), // black
    ]
    static let names = ["Red", "Yellow", "Green", "Blue", "White", "Black"]

    static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

struct Annotation {
    enum Shape {
        case pen([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case highlight(CGRect)
        case text(String, CGPoint)
        case counter(Int, CGPoint)
        case pixelate(CGRect)
    }

    var shape: Shape
    var color: NSColor
    var size: StrokeSize

    /// Tiny accidental drags are discarded.
    var isMeaningful: Bool {
        switch shape {
        case .pen(let points): return !points.isEmpty
        case .line(let a, let b), .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) >= 3
        case .rectangle(let r), .highlight(let r), .pixelate(let r): return r.width >= 3 && r.height >= 3
        case .text(let s, _): return !s.isEmpty
        case .counter: return true
        }
    }

    static func font(for size: StrokeSize) -> NSFont {
        .systemFont(ofSize: size.fontSize, weight: .bold)
    }

    static func textAttributes(color: NSColor, size: StrokeSize) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = Palette.isLight(color) ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 1, alpha: 0.7)
        return [.font: font(for: size), .foregroundColor: color, .shadow: shadow]
    }
}

/// Draws annotations in view (point) coordinates. Used both for the live overlay and the final export,
/// so what you see is exactly what gets copied.
struct AnnotationRenderer {
    let image: CGImage
    let viewSize: CGSize
    /// The live overlay draws on a transparent layer above the screenshot, so the highlighter
    /// needs the screenshot pixels underneath it to multiply against.
    let drawsHighlightBackdrop: Bool

    func draw(_ annotation: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let color = annotation.color.cgColor
        let width = annotation.size.lineWidth
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch annotation.shape {
        case .pen(let points):
            ctx.addPath(Self.smoothPath(points))
            ctx.strokePath()

        case .line(let a, let b):
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()

        case .arrow(let a, let b):
            drawArrow(from: a, to: b, width: width, in: ctx)

        case .rectangle(let r):
            ctx.setLineJoin(.miter)
            ctx.stroke(r)

        case .highlight(let r):
            if drawsHighlightBackdrop {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.draw(image, in: CGRect(origin: .zero, size: viewSize))
                ctx.restoreGState()
            }
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(annotation.color.withAlphaComponent(0.55).cgColor)
            ctx.fill(r)

        case .text(let string, let origin):
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: string, attributes: Annotation.textAttributes(color: annotation.color, size: annotation.size))
                .draw(at: origin)
            NSGraphicsContext.current = previous

        case .counter(let number, let center):
            let d = annotation.size.counterDiameter
            let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.4))
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1.5, d / 14))
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))

            let textColor: NSColor = Palette.isLight(annotation.color) ? .black : .white
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                .foregroundColor: textColor,
            ])
            let size = label.size()
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            NSGraphicsContext.current = previous

        case .pixelate(let r):
            drawPixelated(r, in: ctx)
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, width: CGFloat, in ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let headLength = min(max(12, width * 4), length)
        let headHalfWidth = headLength * 0.5

        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let shaftEnd = CGPoint(x: b.x - ux * headLength * 0.7, y: b.y - uy * headLength * 0.7)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        ctx.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        ctx.closePath()
        ctx.setLineWidth(max(1, width / 2))
        ctx.drawPath(using: .fillStroke)
    }

    private func drawPixelated(_ r: CGRect, in ctx: CGContext) {
        let rect = r.intersection(CGRect(origin: .zero, size: viewSize))
        guard !rect.isEmpty else { return }
        let sx = CGFloat(image.width) / viewSize.width
        let sy = CGFloat(image.height) / viewSize.height
        let pixels = CGRect(x: rect.minX * sx, y: (viewSize.height - rect.maxY) * sy,
                            width: rect.width * sx, height: rect.height * sy).integral
        guard let crop = image.cropping(to: pixels) else { return }

        let block: CGFloat = 10
        let w = max(1, Int(rect.width / block)), h = max(1, Int(rect.height / block))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tiny = small.makeImage() else { return }
        ctx.interpolationQuality = .none
        ctx.draw(tiny, in: rect)
    }

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first) // a dot (round cap)
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
