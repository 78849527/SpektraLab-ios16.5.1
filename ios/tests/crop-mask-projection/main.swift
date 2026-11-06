import CoreGraphics
import CoreImage
import Foundation

func verify(_ statement: @autoclosure () -> Bool, _ label: String) {
    if !statement() { fatalError("Cropped mask projection: " + label) }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.0001 }
func roundTrip(_ projection: MaskDisplayProjection,
               _ sourceUV: CGPoint, _ label: String) {
    let result = projection.toSource(projection.toCanvas(sourceUV))
    verify(close(result.x, sourceUV.x) && close(result.y, sourceUV.y), label)
}
let image = CGSize(width: 1200, height: 800)
let frame = CGRect(x: 0, y: 0, width: 360, height: 240)
let untouched = MaskDisplayProjection(sourceSize: image,
 displayRect: frame, geometry: .identity)
roundTrip(untouched, CGPoint(x: 0.31, y: 0.71), "original image")
verify(close(untouched.toCanvas(CGPoint(x: 0.5, y: 0.5)).x, 180), "source midpoint")
var crop = PhotoGeometry.identity
crop.crop = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75)
let viewport = CGRect(x: 31, y: 43, width: 220, height: 330)
let selected = MaskDisplayProjection(sourceSize: image,
 displayRect: viewport, geometry: crop)
roundTrip(selected, CGPoint(x: 0.38, y: 0.27), "cropped point")
roundTrip(selected, CGPoint(x: 0.69, y: 0.80), "cropped opposite")
verify(selected.toCanvas(CGPoint(x: 0.03, y: 0.5)).x < viewport.minX,
       "hidden source mask remains outside crop")
let moved = selected.sourceDelta(for: CGSize(width: 20, height: -10))
verify(moved.width > 0 && moved.height < 0, "crop-aware line delta")
let radial = MaskComponent.make(.radialGradient)
let radialHandle = selected.radialSourceHandle(radial, horizontal: true)
verify(radialHandle.x > radial.a.x, "radial source handle")
var turn = PhotoGeometry.identity
turn.quarterTurns = 1
let rotated = MaskDisplayProjection(sourceSize: image,
 displayRect: CGRect(x: 0, y: 0, width: 240, height: 360), geometry: turn)
roundTrip(rotated, CGPoint(x: 0.14, y: 0.25), "90 degree point")
roundTrip(rotated, CGPoint(x: 0.79, y: 0.63), "90 degree second point")
verify(close(rotated.toCanvas(CGPoint(x: 0, y: 0)).x, 240), "rotation sense")
var flip = crop
flip.flipHorizontal = true
flip.flipVertical = true
roundTrip(MaskDisplayProjection(sourceSize: image,
 displayRect: viewport, geometry: flip),
 CGPoint(x: 0.48, y: 0.52), "mirror and crop")
var straighten = crop
straighten.straightenDegrees = 7.5
roundTrip(MaskDisplayProjection(sourceSize: image,
 displayRect: viewport, geometry: straighten),
 CGPoint(x: 0.52, y: 0.46), "straighten and crop")
straighten.flipHorizontal = true
straighten.quarterTurns = 3
let combined = MaskDisplayProjection(sourceSize: image,
 displayRect: viewport, geometry: straighten)
roundTrip(combined, CGPoint(x: 0.50, y: 0.50),
          "flip, quarter turn, straighten and crop")
let d = combined.sourceDelta(for: CGSize(width: 23, height: 13))
let a = combined.toSource(CGPoint(x: viewport.midX, y: viewport.midY), clamp: false)
let b = combined.toSource(CGPoint(x: viewport.midX + 23,
                                  y: viewport.midY + 13), clamp: false)
verify(close(d.width, b.x - a.x) && close(d.height, b.y - a.y),
       "delta is the inverse of the display transform")
print("CROP_MASK_PROJECTION_BUILD32_PASS")
