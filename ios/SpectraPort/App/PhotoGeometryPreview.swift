import CoreImage
import UIKit

/// Compact 1440px preview only. Never changes the original spectral print,
/// and the exact same Core Image geometry runs on full-size export pixels.
enum PhotoGeometryPreview {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: UIImage, geometry: PhotoGeometry,
                       onlyOrientation: Bool = false) -> UIImage {
        guard let cg = image.cgImage else { return image }
        if geometry.isIdentity { return image }
        let source = CIImage(cgImage: cg)
        let changed = onlyOrientation ? geometry.oriented(source) : geometry.apply(to: source)
        guard changed.extent.width > 1, changed.extent.height > 1,
              let output = context.createCGImage(changed, from: changed.extent) else {
            return image
        }
        return UIImage(cgImage: output)
    }
}
