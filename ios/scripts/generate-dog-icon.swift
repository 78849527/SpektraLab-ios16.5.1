import AppKit
import CoreGraphics
import Foundation

// Deterministic vector Shiba-dog app icon, rendered locally by macOS
// in GitHub Actions. No network, artwork downloads, font files or binary
// blobs are required in the source repository.
let root = URL(fileURLWithPath: "ios/SpectraPort/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func color(_ rgb: UInt32) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat((rgb >> 16) & 255) / 255,
                         CGFloat((rgb >> 8) & 255) / 255,
                         CGFloat(rgb & 255) / 255, 1])!
}

func ellipse(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
             _ w: CGFloat, _ h: CGFloat, _ fill: UInt32) {
    ctx.setFillColor(color(fill))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
}

func polygon(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)], _ fill: UInt32) {
    guard let first = pts.first else { return }
    let p = CGMutablePath()
    p.move(to: CGPoint(x: first.0, y: first.1))
    for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(color(fill))
    ctx.fillPath()
}

func strokeSmile(_ ctx: CGContext, points: [CGPoint], fill: UInt32,
                 width: CGFloat) {
    let p = CGMutablePath()
    if let start = points.first { p.move(to: start) }
    if points.count >= 3 {
        p.addQuadCurve(to: points[2], control: points[1])
    }
    ctx.addPath(p)
    ctx.setStrokeColor(color(fill))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

func render(_ ctx: CGContext) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // Deep darkroom background, edge-to-edge, fully opaque.
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [color(0x2B2622), color(0x0F1215)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 85, y: 80),
                           end: CGPoint(x: 925, y: 950), options: [])
    ctx.setStrokeColor(color(0x715439))
    ctx.setLineWidth(9)
    ctx.strokeEllipse(in: CGRect(x: 107, y: 95, width: 810, height: 810))

    // Shiba ears, distinctive enough at 60px home-screen size.
    polygon(ctx, [(255,404),(252,177),(289,108),(450,301)],0xDA9D50)
    polygon(ctx, [(769,404),(772,177),(735,108),(574,301)],0xDA9D50)
    polygon(ctx, [(300,316),(299,201),(322,173),(410,305)],0x8B5540)
    polygon(ctx, [(724,316),(725,201),(702,173),(614,305)],0x8B5540)
    ellipse(ctx, 203, 224, 618, 654, 0xDF9F54)
    ellipse(ctx, 226, 238, 572, 600, 0xEEC17C)

    // Brow/eyes and cream cheek/muzzle.
    ellipse(ctx, 290, 390, 190, 115, 0xD69B59)
    ellipse(ctx, 545, 390, 190, 115, 0xD69B59)
    ellipse(ctx, 291, 535, 240, 290, 0xFFEAC0)
    ellipse(ctx, 493, 535, 240, 290, 0xFFEAC0)
    ellipse(ctx, 357, 425, 53, 72, 0x211F1D)
    ellipse(ctx, 615, 425, 53, 72, 0x211F1D)
    ellipse(ctx, 372, 439, 16, 16, 0xFFF8DF)
    ellipse(ctx, 630, 439, 16, 16, 0xFFF8DF)

    // Nose and joyful smile.
    ellipse(ctx, 452, 601, 120, 72, 0x2D2623)
    strokeSmile(ctx, points: [
        CGPoint(x: 512, y: 663), CGPoint(x: 491, y: 728),
        CGPoint(x: 454, y: 712)], fill: 0x543A31, width: 13)
    strokeSmile(ctx, points: [
        CGPoint(x: 512, y: 663), CGPoint(x: 533, y: 728),
        CGPoint(x: 570, y: 712)], fill: 0x543A31, width: 13)
    ellipse(ctx, 488, 742, 48, 77, 0xCA7C6E)
}

func write(_ size: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SpectraPortIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    render(ctx)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SpectraPortIcon", code: 2)
    }
    try png.write(to: root.appendingPathComponent(name), options: .atomic)
}

let variants: [(Int, String)] = [
    (40, "AppIcon-20@2.png"),
    (60, "AppIcon-20@3.png"),
    (58, "AppIcon-29@2.png"),
    (87, "AppIcon-29@3.png"),
    (80, "AppIcon-40@2.png"),
    (120, "AppIcon-40@3.png"),
    (120, "AppIcon-60@2.png"),
    (180, "AppIcon-60@3.png"),
    (1024, "AppIcon-1024.png")
]
for (size, filename) in variants { try write(size, name: filename) }
print("SpectraPort dog icon generated: \(variants.count) assets (1024px master)")
