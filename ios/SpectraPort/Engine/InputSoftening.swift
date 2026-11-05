import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A deliberately subtle spatial pre-processing control for photos that have
/// strong phone ISP sharpening. This does not reconstruct sensor detail or
/// reverse a proprietary sharpening algorithm. Applied before the original
/// SpektraLab film development to preserve the engine's generated grain.
enum InputSoftening {
    static func apply(_ image: CIImage, amount: Double) -> CIImage {
        let strength = min(1, max(0, amount))
        guard strength > 0 else { return image }
        let extent = image.extent
        let relativeScale = max(extent.width, extent.height) / 1440.0
        let radius = Float(max(0.2, (0.65 + 0.55 * strength) * relativeScale))

        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = image.clampedToExtent()
        gaussian.radius = radius
        guard let blurred = gaussian.outputImage?.cropped(to: extent) else {
            return image
        }

        let mix = CIFilter.mix()
        mix.backgroundImage = image
        mix.inputImage = blurred
        mix.amount = Float(strength * 0.7)
        return mix.outputImage?.cropped(to: extent) ?? image
    }
}
