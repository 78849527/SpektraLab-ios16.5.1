import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// Objective indication that two successfully rendered frames are actually
/// different. Both images are colour-managed into sRGB at a fixed 80x80
/// sample. Mean absolute difference is an image diagnostic, not a perceptual
/// Delta E or a promise that the effect should be visually dramatic.
enum PreviewDifference {
    private static let edge = 80
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func smallRGBA(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              cg.width > 0, cg.height > 0 else { return nil }

        let sx = CGFloat(edge) / CGFloat(cg.width)
        let sy = CGFloat(edge) / CGFloat(cg.height)
        let resized = CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(scaleX: sx, y: sy)
        )
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(
                resized,
                toBitmap: base,
                rowBytes: edge * 4,
                bounds: CGRect(x: 0, y: 0, width: edge, height: edge),
                format: .RGBA8,
                colorSpace: space
            )
        }
        return bytes
    }

    static func averageRGBChangePercent(from previous: UIImage, to current: UIImage) -> Double? {
        guard let a = smallRGBA(previous),
              let b = smallRGBA(current),
              a.count == b.count else { return nil }
        var sum: UInt64 = 0
        for offset in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 {
                sum += UInt64(abs(Int(a[offset + channel]) - Int(b[offset + channel])))
            }
        }
        return Double(sum) / Double(edge * edge * 3 * 255) * 100
    }
}
