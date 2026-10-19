// Renders the 1024×1024 app icon PNG. Usage: swift scripts/make_icon.swift out.png
import AppKit

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)

// Rounded-square background with a diagonal gradient.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(red: 0.16, green: 0.45, blue: 1.0, alpha: 1),
                                   CGColor(red: 0.47, green: 0.25, blue: 0.95, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
ctx.restoreGState()

// Viewfinder corners.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let frame = tile.insetBy(dx: 150, dy: 150)
let arm: CGFloat = 130
for (cx, cy, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                         (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx, y: cy + dy * arm))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
}
ctx.strokePath()

// Dashed selection rectangle in the middle.
let selection = frame.insetBy(dx: 115, dy: 140)
ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
ctx.fill(selection)
ctx.setLineWidth(18)
ctx.setLineDash(phase: 0, lengths: [42, 28])
ctx.stroke(selection)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
