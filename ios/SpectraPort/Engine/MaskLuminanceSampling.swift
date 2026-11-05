import CoreGraphics
import Foundation

/// The original Metal luminanceCoverage() works in encoded ROMM RGB.
/// Sample the displayed CGImage through a 1x1 ROMM bitmap context so
/// ColorSync handles its source profile and no full-size bitmap is allocated.
enum MaskLuminanceSampling {
    static func sample(_ image: CGImage, at p: CGPoint) -> Double? {
        guard image.width > 0, image.height > 0,
              p.x.isFinite, p.y.isFinite,
              (0...1).contains(p.x), (0...1).contains(p.y),
              let romm = CGColorSpace(name: CGColorSpace.rommrgb) else { return nil }
        let px = min(image.width - 1, Int(p.x * CGFloat(image.width)))
        let py = min(image.height - 1, Int(p.y * CGFloat(image.height)))
        guard let cropped = image.cropping(
            to: CGRect(x: px, y: py, width: 1, height: 1)
        ) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { bytes -> Double? in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: romm,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                            CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let r = Double(bytes[0]) / 255
            let g = Double(bytes[1]) / 255
            let b = Double(bytes[2]) / 255
            return max(0, min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b))
        }
    }

    static func range(around value: Double) -> (low: Double, high: Double) {
        let c = max(0, min(1, value))
        return (max(0, c - 0.12), min(1, c + 0.12))
    }
}
