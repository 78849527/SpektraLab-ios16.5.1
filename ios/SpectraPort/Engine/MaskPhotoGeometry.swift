import CoreGraphics
import Foundation

/// Converts the desktop's resolution-independent mask coordinates to the
/// exact aspect-fit frame used by DetailImageScrollView when zoom is locked
/// to its minimum scale. No image pixels, shaders or export data are changed.
enum MaskPhotoGeometry {
    static func fittedRect(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width,
                        viewport.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(x: (viewport.width - width) / 2,
                      y: (viewport.height - height) / 2,
                      width: width, height: height)
    }

    static func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height)
    }

    static func normalized(_ location: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: max(0, min(1, (location.x - rect.minX) / rect.width)),
            y: max(0, min(1, (location.y - rect.minY) / rect.height))
        )
    }

    /// The original Metal kernel evaluates ellipse radii in units of the
    /// image's longer edge (see Shaders.metal::toLongEdge).
    static func radialHandle(
        center: CGPoint, radii: CGSize, angleDegrees: Double,
        rect: CGRect, horizontal: Bool
    ) -> CGPoint {
        let origin = point(center, in: rect)
        let theta = CGFloat(angleDegrees * .pi / 180)
        let length = max(rect.width, rect.height)
        let radius = length * (horizontal ? radii.width : radii.height)
        return horizontal
            ? CGPoint(x: origin.x + radius * cos(theta),
                      y: origin.y + radius * sin(theta))
            : CGPoint(x: origin.x - radius * sin(theta),
                      y: origin.y + radius * cos(theta))
    }

    static func radius(
        for touch: CGPoint, center: CGPoint, angleDegrees: Double,
        rect: CGRect, horizontal: Bool
    ) -> CGFloat {
        let origin = point(center, in: rect)
        let dx = touch.x - origin.x
        let dy = touch.y - origin.y
        let theta = CGFloat(angleDegrees * .pi / 180)
        let axis = horizontal
            ? dx * cos(theta) + dy * sin(theta)
            : -dx * sin(theta) + dy * cos(theta)
        return max(0.03, min(0.7, axis / max(1, max(rect.width, rect.height))))
    }
}
