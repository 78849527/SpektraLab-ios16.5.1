import CoreGraphics
import Foundation

/// Maps a fixed cropped/rotated photo preview to original-image mask UVs.
/// The masks remain unchanged for the original desktop Metal kernel.
/// The geometry order must agree with PhotoGeometry.oriented/apply:
/// flip -> quarter turns -> fine straighten -> central trim -> crop.
struct MaskDisplayProjection {
    let sourceSize: CGSize
    let displayRect: CGRect
    let geometry: PhotoGeometry

    private let sourceW: CGFloat
    private let sourceH: CGFloat
    private let turnW: CGFloat
    private let turnH: CGFloat
    private let turns: Int
    private let sine: CGFloat
    private let cosine: CGFloat
    private let rotatedW: CGFloat
    private let rotatedH: CGFloat
    private let trimX: CGFloat
    private let trimY: CGFloat
    private let cropX: CGFloat
    private let cropY: CGFloat
    private let cropW: CGFloat
    private let cropH: CGFloat

    init(sourceSize: CGSize, displayRect: CGRect, geometry: PhotoGeometry) {
        self.sourceSize = sourceSize
        self.displayRect = displayRect
        self.geometry = geometry
        let w = max(1, sourceSize.width), h = max(1, sourceSize.height)
        sourceW = w
        sourceH = h
        let q = ((geometry.quarterTurns % 4) + 4) % 4
        turns = q
        let w0 = q % 2 == 0 ? w : h
        let h0 = q % 2 == 0 ? h : w
        turnW = w0
        turnH = h0
        let radians = CGFloat(max(-15, min(15, geometry.straightenDegrees))) * .pi / 180
        let sn = sin(radians), cs = cos(radians)
        sine = sn
        cosine = cs
        let bw = abs(cs) * w0 + abs(sn) * h0
        let bh = abs(cs) * h0 + abs(sn) * w0
        rotatedW = bw
        rotatedH = bh
        let outW: CGFloat
        let outH: CGFloat
        if abs(radians) > 0.000001 {
            let scale = min(w0 / bw, h0 / bh)
            outW = max(1, floor(w0 * scale))
            outH = max(1, floor(h0 * scale))
            trimX = floor((bw - outW) / 2)
            trimY = floor((bh - outH) / 2)
        } else {
            outW = w0
            outH = h0
            trimX = 0
            trimY = 0
        }
        let c = PhotoGeometry.bounded(geometry.crop)
        if c == PhotoGeometry.unitRect {
            cropX = 0
            cropY = 0
            cropW = outW
            cropH = outH
        } else {
            let x = floor(c.minX * outW)
            let y = floor((1 - c.maxY) * outH)
            cropX = x
            cropY = y
            cropW = max(1, min(outW - x, floor(c.width * outW)))
            cropH = max(1, min(outH - y, floor(c.height * outH)))
        }
    }

    /// Project a source mask point, retaining points outside the crop.
    func toCanvas(_ point: CGPoint) -> CGPoint {
        var x = point.x * sourceW
        var y = (1 - point.y) * sourceH
        if geometry.flipHorizontal { x = sourceW - x }
        if geometry.flipVertical { y = sourceH - y }
        switch turns {
        case 1: (x, y) = (y, sourceW - x)
        case 2: (x, y) = (sourceW - x, sourceH - y)
        case 3: (x, y) = (sourceH - y, x)
        default: break
        }
        if abs(sine) > 0.000001 {
            let u = x - turnW / 2, v = y - turnH / 2
            x = u * cosine + v * sine + rotatedW / 2 - trimX
            y = -u * sine + v * cosine + rotatedH / 2 - trimY
        }
        x -= cropX
        y -= cropY
        return CGPoint(x: displayRect.minX + x / cropW * displayRect.width,
                       y: displayRect.minY + (1 - y / cropH) * displayRect.height)
    }

    /// Invert a canvas touch back into the native uncut mask coordinate.
    func toSource(_ point: CGPoint, clamp: Bool = true) -> CGPoint {
        guard displayRect.width > 0 && displayRect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        var x = (point.x - displayRect.minX) / displayRect.width * cropW + cropX
        var y = (1 - (point.y - displayRect.minY) / displayRect.height) * cropH + cropY
        if abs(sine) > 0.000001 {
            let u = x + trimX - rotatedW / 2
            let v = y + trimY - rotatedH / 2
            x = u * cosine - v * sine + turnW / 2
            y = u * sine + v * cosine + turnH / 2
        }
        switch turns {
        case 1: (x, y) = (sourceW - y, x)
        case 2: (x, y) = (sourceW - x, sourceH - y)
        case 3: (x, y) = (y, sourceH - x)
        default: break
        }
        if geometry.flipHorizontal { x = sourceW - x }
        if geometry.flipVertical { y = sourceH - y }
        let u = x / sourceW, v = 1 - y / sourceH
        return clamp
            ? CGPoint(x: max(0, min(1, u)), y: max(0, min(1, v)))
            : CGPoint(x: u, y: v)
    }

    func sourceDelta(for translated: CGSize) -> CGSize {
        let middle = CGPoint(x: displayRect.midX, y: displayRect.midY)
        let a = toSource(middle, clamp: false)
        let b = toSource(CGPoint(x: middle.x + translated.width,
                                y: middle.y + translated.height), clamp: false)
        return CGSize(width: b.x - a.x, height: b.y - a.y)
    }

    /// The desktop radial radii use units of the source's longest side.
    func radialSourceHandle(_ shape: MaskComponent, horizontal: Bool) -> CGPoint {
        let theta = CGFloat(shape.angle * .pi / 180)
        let amount = (horizontal ? shape.radii.width : shape.radii.height) *
                     max(sourceW, sourceH)
        let dx = horizontal ? amount * cos(theta) : -amount * sin(theta)
        let dy = horizontal ? amount * sin(theta) : amount * cos(theta)
        return CGPoint(x: shape.a.x + dx / sourceW,
                       y: shape.a.y + dy / sourceH)
    }

    func radialSourceBoundary(_ shape: MaskComponent, angle: CGFloat) -> CGPoint {
        let theta = CGFloat(shape.angle * .pi / 180)
        let longSide = max(sourceW, sourceH)
        let u = cos(angle) * shape.radii.width * longSide
        let v = sin(angle) * shape.radii.height * longSide
        return CGPoint(x: shape.a.x + (u * cos(theta) - v * sin(theta)) / sourceW,
                       y: shape.a.y + (u * sin(theta) + v * cos(theta)) / sourceH)
    }

    func radialRadius(for touch: CGPoint, shape: MaskComponent,
                      horizontal: Bool) -> CGFloat {
        let uv = toSource(touch)
        let dx = (uv.x - shape.a.x) * sourceW
        let dy = (uv.y - shape.a.y) * sourceH
        let theta = CGFloat(shape.angle * .pi / 180)
        let projection = horizontal
            ? dx * cos(theta) + dy * sin(theta)
            : -dx * sin(theta) + dy * cos(theta)
        return max(0.03, min(0.7, projection / max(sourceW, sourceH)))
    }
}
