import CoreGraphics
import CoreImage
import Foundation

/// Photo-specific, non-destructive geometry. Top-left normalized crop rect
/// follows the same coordinate convention as the native iOS mask canvas.
/// The physical negative and desktop Layer 2 parameters remain unchanged.
enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free = "自由"
    case original = "原始"
    case square = "1:1"
    case standard = "4:3"
    case classic = "3:2"
    case portrait = "9:16"

    var id: String { rawValue }

    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.width / max(1, imageSize.height)
        case .square: return 1
        case .standard: return 4.0 / 3.0
        case .classic: return 3.0 / 2.0
        case .portrait: return 9.0 / 16.0
        }
    }
}

enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }
}

struct PhotoGeometry: Equatable {
    static let identity = PhotoGeometry()
    static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    var crop: CGRect = unitRect
    var quarterTurns: Int = 0     // positive = 90 degrees clockwise
    var straightenDegrees: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    var aspect: CropAspectPreset = .free

    var isIdentity: Bool {
        crop == Self.unitRect && quarterTurns % 4 == 0 &&
        abs(straightenDegrees) < 0.00001 && !flipHorizontal && !flipVertical
    }

    /// Clamp crop to valid positive-area photo coordinates.
    static func bounded(_ rect: CGRect) -> CGRect {
        let w = min(1, max(0.12, rect.width))
        let h = min(1, max(0.12, rect.height))
        return CGRect(x: min(max(0, rect.minX), 1 - w),
                      y: min(max(0, rect.minY), 1 - h), width: w, height: h)
    }

    func selectingAspect(_ option: CropAspectPreset, imageSize: CGSize) -> PhotoGeometry {
        var next = self
        next.aspect = option
        guard imageSize.width > 0, imageSize.height > 0,
              let target = option.ratio(imageSize: imageSize) else { return next }
        let normalizedRatio = target / (imageSize.width / imageSize.height)
        let width = normalizedRatio >= 1 ? 1.0 : max(0.12, normalizedRatio)
        let height = normalizedRatio >= 1 ? max(0.12, 1 / normalizedRatio) : 1.0
        next.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2,
                           width: width, height: height)
        return next
    }

    func turned(_ change: Int) -> PhotoGeometry {
        var next = self
        next.quarterTurns = (quarterTurns + change + 8) % 4
        // Rotating a crop needs remapping its corners. Starting from a whole
        // oriented photo makes the result explicit and prevents invisible crop.
        next.crop = Self.unitRect
        next.aspect = .free
        return next
    }

    func moved(by fraction: CGSize, from start: CGRect) -> PhotoGeometry {
        var next = self
        let initial = Self.bounded(start)
        next.crop = CGRect(
            x: min(max(0, initial.minX + fraction.width), 1 - initial.width),
            y: min(max(0, initial.minY + fraction.height), 1 - initial.height),
            width: initial.width, height: initial.height)
        return next
    }

    func resized(corner: CropCorner, to touch: CGPoint,
                 from source: CGRect, imageSize: CGSize) -> PhotoGeometry {
        let start = Self.bounded(source)
        let anchor = CGPoint(x: corner.left ? start.maxX : start.minX,
                             y: corner.top ? start.maxY : start.minY)
        let limitW = corner.left ? anchor.x : 1 - anchor.x
        let limitH = corner.top ? anchor.y : 1 - anchor.y
        var width = min(limitW, max(0.12, abs(touch.x - anchor.x)))
        var height = min(limitH, max(0.12, abs(touch.y - anchor.y)))
        if let target = aspect.ratio(imageSize: imageSize),
           imageSize.width > 0, imageSize.height > 0 {
            let normRatio = target / (imageSize.width / imageSize.height)
            width = min(width, height * normRatio, limitW, limitH * normRatio)
            height = width / normRatio
        }
        var next = self
        next.crop = Self.bounded(CGRect(
            x: corner.left ? anchor.x - width : anchor.x,
            y: corner.top ? anchor.y - height : anchor.y,
            width: width, height: height))
        return next
    }

    private static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// The entire photo in its chosen orientation. A conservative centred
    /// inscribed rectangle after fine straightening removes transparent corners.
    func oriented(_ original: CIImage) -> CIImage {
        var image = Self.normalize(original)
        if flipHorizontal {
            image = Self.normalize(image.transformed(
                by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        if flipVertical {
            image = Self.normalize(image.transformed(
                by: CGAffineTransform(scaleX: 1, y: -1)))
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            image = Self.normalize(image.transformed(by: CGAffineTransform(
                rotationAngle: -CGFloat(turns) * .pi / 2)))
        }
        let angle = CGFloat(max(-15, min(15, straightenDegrees))) * .pi / 180
        if abs(angle) > 0.000001 {
            let size = image.extent.size
            let sine = abs(sin(angle)), cosine = abs(cos(angle))
            // These inequalities guarantee every point in the central
            // rectangle maps inside the original image after rotation.
            let fitX = size.width / (size.width * cosine + size.height * sine)
            let fitY = size.height / (size.height * cosine + size.width * sine)
            let scale = min(fitX, fitY)
            image = Self.normalize(image.transformed(
                by: CGAffineTransform(rotationAngle: -angle)))
            let safeW = max(1, floor(size.width * scale))
            let safeH = max(1, floor(size.height * scale))
            let safe = CGRect(
                x: floor((image.extent.width - safeW) / 2),
                y: floor((image.extent.height - safeH) / 2),
                width: safeW, height: safeH)
            image = Self.normalize(image.cropped(to: safe))
        }
        return image
    }

    /// Crop remains normalized across 1440px preview and 6MP/12.5MP export.
    /// Core Image uses bottom-left coordinates; the UI uses top-left.
    func apply(to input: CIImage) -> CIImage {
        if isIdentity { return input }
        let oriented = oriented(input)
        let bounded = Self.bounded(crop)
        if bounded == Self.unitRect { return oriented }
        let bounds = oriented.extent
        let x = floor(bounds.minX + bounded.minX * bounds.width)
        let y = floor(bounds.minY + (1 - bounded.maxY) * bounds.height)
        let w = max(1, min(bounds.maxX - x, floor(bounded.width * bounds.width)))
        let h = max(1, min(bounds.maxY - y, floor(bounded.height * bounds.height)))
        return Self.normalize(oriented.cropped(
            to: CGRect(x: x, y: y, width: w, height: h)))
    }
}
