import CoreGraphics
import Foundation

func verify(_ condition: @autoclosure () -> Bool, _ explanation: String) {
    if !condition() { fatalError("Photo-space mask geometry: " + explanation) }
}
func close(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.0001) -> Bool {
    abs(a - b) < tolerance
}

// Portrait crop-to-fit uses the same minimum ratio as DetailImageScrollView.
let portrait = MaskPhotoGeometry.fittedRect(
    image: CGSize(width: 3000, height: 4000),
    viewport: CGSize(width: 390, height: 500))
verify(close(portrait.width, 375) && close(portrait.height, 500),
       "portrait aspect fit")
verify(close(portrait.minX, 7.5) && close(portrait.minY, 0),
       "portrait centered letterboxing")
let center = MaskPhotoGeometry.point(
    CGPoint(x: 0.5, y: 0.5), in: portrait)
verify(close(center.x, 195) && close(center.y, 250),
       "portrait center projected")
let roundtrip = MaskPhotoGeometry.normalized(center, in: portrait)
verify(close(roundtrip.x, 0.5) && close(roundtrip.y, 0.5),
       "project/normalize roundtrip")
let outside = MaskPhotoGeometry.normalized(
    CGPoint(x: -800, y: 3000), in: portrait)
verify(close(outside.x, 0) && close(outside.y, 1),
       "dragged handle clamped to photo boundaries")

let landscape = MaskPhotoGeometry.fittedRect(
    image: CGSize(width: 4032, height: 3024),
    viewport: CGSize(width: 390, height: 540))
verify(close(landscape.width, 390) && close(landscape.height, 292.5),
       "landscape aspect fit")
verify(close(landscape.minX, 0) && close(landscape.minY, 123.75),
       "landscape vertical letterbox")

// Portrait radius units are normalised to the *long edge*, not photo width.
let c = CGPoint(x: 0.5, y: 0.5)
let radii = CGSize(width: 0.3, height: 0.2)
let h = MaskPhotoGeometry.radialHandle(
    center: c, radii: radii, angleDegrees: 0,
    rect: portrait, horizontal: true)
let v = MaskPhotoGeometry.radialHandle(
    center: c, radii: radii, angleDegrees: 0,
    rect: portrait, horizontal: false)
verify(close(h.x - center.x, 150) && close(h.y, center.y),
       "horizontal radius on portrait long-edge")
verify(close(v.y - center.y, 100) && close(v.x, center.x),
       "vertical radius on portrait long-edge")

// Rotated radial control handles must align with the unchanged Mac shader
// coordinate transform and produce identical saved radii after dragging.
let rotated = MaskPhotoGeometry.radialHandle(
    center: c, radii: radii, angleDegrees: 90,
    rect: landscape, horizontal: true)
let extracted = MaskPhotoGeometry.radius(
    for: rotated, center: c, angleDegrees: 90,
    rect: landscape, horizontal: true)
verify(close(extracted, radii.width), "90-degree radius roundtrip")

let narrow = MaskPhotoGeometry.radius(
    for: CGPoint(x: 0, y: 0), center: c, angleDegrees: 0,
    rect: portrait, horizontal: true)
verify(close(narrow, 0.03), "minimum control radius")
let broad = MaskPhotoGeometry.radius(
    for: CGPoint(x: 2000, y: 2000), center: c, angleDegrees: 0,
    rect: portrait, horizontal: true)
verify(close(broad, 0.7), "maximum control radius")


// The preview source can change from a 1440px render to another image size
// without changing the aspect-fit photo/handle rectangle in Scheme A.
let portraitPreview = MaskPhotoGeometry.fittedRect(
    image: CGSize(width: 1080, height: 1440),
    viewport: CGSize(width: 390, height: 500))
verify(close(portraitPreview.minX, portrait.minX) &&
       close(portraitPreview.minY, portrait.minY) &&
       close(portraitPreview.width, portrait.width) &&
       close(portraitPreview.height, portrait.height),
       "same aspect ratio and viewport keep fixed local canvas geometry")
let portraitHandle = MaskPhotoGeometry.point(
    CGPoint(x: 0.25, y: 0.75), in: portraitPreview)
let fullHandle = MaskPhotoGeometry.point(
    CGPoint(x: 0.25, y: 0.75), in: portrait)
verify(close(portraitHandle.x, fullHandle.x) &&
       close(portraitHandle.y, fullHandle.y),
       "live preview image replacement does not shift mask handle")

print("MASK_PHOTO_GEOMETRY_PASS: portrait, landscape, handles, rotation, clamps")
