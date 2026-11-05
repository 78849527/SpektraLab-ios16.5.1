import CoreGraphics
import CoreImage
import Foundation

func check(_ test: @autoclosure () -> Bool, _ name: String) {
    if !test() { fatalError("Geometry parity: " + name) }
}
func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1.0) -> Bool {
    abs(a - b) <= tolerance
}
let flat = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7))
    .cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
let source = PhotoGeometry.identity
check(source.apply(to: flat).extent == flat.extent, "identity preserves native extent")
let rotated = source.turned(1)
let turns = rotated.apply(to: flat).extent
check(near(turns.width, 800) && near(turns.height, 1200), "quarter turn dimensions")
let twice = source.turned(2).apply(to: flat).extent
check(near(twice.width, 1200) && near(twice.height, 800), "half turn dimensions")
let square = source.selectingAspect(.square, imageSize: CGSize(width: 1200, height: 800))
let squareImage = square.apply(to: flat).extent
check(near(squareImage.width, squareImage.height), "square export result")
let portrait = source.selectingAspect(.portrait, imageSize: CGSize(width: 1200, height: 800))
let portraitImage = portrait.apply(to: flat).extent
check(abs(portraitImage.width / portraitImage.height - 9.0 / 16.0) < 0.02, "portrait aspect")
let shifted = square.moved(by: CGSize(width: 9, height: -8), from: square.crop)
check(shifted.crop.minX >= 0 && shifted.crop.minY >= 0 && shifted.crop.maxX <= 1 &&
      shifted.crop.maxY <= 1, "crop stays inside source")
let pulled = source.resized(corner: .topLeft, to: CGPoint(x: 0.3, y: 0.3),
                            from: .unitRect, imageSize: CGSize(width: 1200, height: 800))
check(pulled.crop.width > 0.6 && pulled.crop.height > 0.6, "corner reduction")
var tilted = source
tilted.straightenDegrees = 8
let upright = tilted.oriented(flat)
check(upright.extent.width < 1200 && upright.extent.height < 800,
      "straighten safely removes transparent corners")
let flipped = PhotoGeometry(crop: .unitRect, quarterTurns: 0,
                            straightenDegrees: 0, flipHorizontal: true,
                            flipVertical: true, aspect: .free)
check(near(flipped.apply(to: flat).extent.width, 1200), "mirror preserves width")
print("PHOTO_GEOMETRY_PARITY_PASS")
