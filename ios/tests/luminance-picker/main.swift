import CoreGraphics
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("Luminance-picker fixture: " + message) }
}
guard let romm = CGColorSpace(name: CGColorSpace.rommrgb),
      let c = CGContext(data: nil, width: 2, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 8,
                        space: romm, bitmapInfo:
                        CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ROMM test context unavailable")
}
c.setFillColor(CGColor(colorSpace: romm, components: [0.2, 0.2, 0.2, 1])!)
c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
c.setFillColor(CGColor(colorSpace: romm, components: [0.8, 0.8, 0.8, 1])!)
c.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
guard let image = c.makeImage(),
      let dark = MaskLuminanceSampling.sample(image, at: CGPoint(x: 0.2, y: 0.5)),
      let bright = MaskLuminanceSampling.sample(image, at: CGPoint(x: 0.8, y: 0.5))
else { fatalError("Cannot sample test bitmap") }
check(abs(dark - 0.2) < 0.04, "sample dark ROMM pixel")
check(abs(bright - 0.8) < 0.04, "sample bright ROMM pixel")
check(bright > dark + 0.4, "photo tap chooses a distinct tone")
let interval = MaskLuminanceSampling.range(around: bright)
check(interval.low < bright && interval.high > bright, "selected range includes sample")
check(MaskLuminanceSampling.range(around: 1).high == 1, "white-bound clamp")
check(MaskLuminanceSampling.sample(image, at: CGPoint(x: -0.1, y: 0.5)) == nil,
      "touch outside photo rejected")
print("LUMINANCE_PICKER_PASS")
