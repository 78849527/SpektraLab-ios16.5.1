import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// RAW sensor decoding ahead of the original SpektraLab spectral engine.
/// The Mac's linear CIRAWFilter look is used: no boost, no local tone map.
/// Never silently use an embedded camera JPEG in place of RAW pixels.
struct RAWDecodeOptions: Equatable {
    var identifierHint: String?
    var useAsShot = true
    var temperature: Double = 5500
    var tint: Double = 0
    var lensCorrection = true

    var safeTemperature: Float { Float(max(2000, min(50000, temperature))) }
    var safeTint: Float { Float(max(-150, min(150, tint))) }
}
struct RAWProbe {
    let temperature: Double
    let tint: Double
    let lensCorrectionSupported: Bool
    let width: Int
    let height: Int
}
enum RAWDevelopmentError: LocalizedError {
    case unsupported, unsafeFileSize, invalidDimensions, failed, noColorSpace
    var errorDescription: String? {
        switch self {
        case .unsupported: "iOS 没有此相机 RAW 的传感器解码器，已拒绝内嵌 JPEG 替代"
        case .unsafeFileSize: "RAW 文件超过 180 MB 的安全限制"
        case .invalidDimensions: "RAW 原始尺寸异常"
        case .failed: "RAW 显影失败，可能是文件损坏或相机型号不受支持"
        case .noColorSpace: "设备缺少 ProPhoto 工作色彩空间"
        }
    }
}

enum RawImageDeveloper {
    static let rawExtensions: Set<String> =
        ["raf", "dng", "nef", "arw", "cr2", "cr3", "rw2", "orf", "pef", "srw", "3fr", "iiq"]

    static func isRaw(filename: String, typeID: String? = nil) -> Bool {
        if rawExtensions.contains((filename as NSString).pathExtension.lowercased()) { return true }
        guard let typeID, let type = UTType(typeID) else { return false }
        return type.conforms(to: .rawImage)
    }

    private static func filter(_ data: Data, options: RAWDecodeOptions) throws -> CIRAWFilter {
        guard !data.isEmpty, data.count <= 180_000_000 else { throw RAWDevelopmentError.unsafeFileSize }
        guard let f = CIRAWFilter(imageData: data, identifierHint: options.identifierHint) else {
            throw RAWDevelopmentError.unsupported
        }
        f.isDraftModeEnabled = false
        f.boostAmount = 0
        f.boostShadowAmount = 0
        f.isGamutMappingEnabled = false
        f.localToneMapAmount = 0
        f.extendedDynamicRangeAmount = 0
        f.isLensCorrectionEnabled = options.lensCorrection && f.isLensCorrectionSupported
        if !options.useAsShot {
            f.neutralTemperature = options.safeTemperature
            f.neutralTint = options.safeTint
        }
        return f
    }

    static func probe(_ data: Data, hint: String?) throws -> RAWProbe {
        let f = try filter(data, options: RAWDecodeOptions(identifierHint: hint))
        guard let image = f.outputImage else { throw RAWDevelopmentError.unsupported }
        let w = image.extent.width, h = image.extent.height
        guard w >= 64, h >= 64, w.isFinite, h.isFinite, w*h < 1_000_000_000 else {
            throw RAWDevelopmentError.invalidDimensions
        }
        return RAWProbe(temperature: Double(f.neutralTemperature),
                        tint: Double(f.neutralTint),
                        lensCorrectionSupported: f.isLensCorrectionSupported,
                        width: Int(w), height: Int(h))
    }

    struct Frame {
        var pixels: [Float]
        let width: Int
        let height: Int
        let nativeWidth: Int
        let nativeHeight: Int
        let preview: CGImage?
    }

    static func develop(_ data: Data, options: RAWDecodeOptions, maxPixels: Int,
                        maxEdge: Int? = nil, softness: Double,
                        context: CIContext, preview: Bool = false) throws -> Frame {
        let f = try filter(data, options: options)
        guard let raw = f.outputImage else { throw RAWDevelopmentError.failed }
        let nativeW = Int(raw.extent.width), nativeH = Int(raw.extent.height)
        guard nativeW >= 64, nativeH >= 64,
              Int64(nativeW) * Int64(nativeH) < 1_000_000_000,
              maxPixels > 0 else { throw RAWDevelopmentError.invalidDimensions }
        let budget = sqrt(Double(maxPixels) * 0.94 / Double(nativeW * nativeH))
        let edge = maxEdge.map { Double($0) / Double(max(nativeW, nativeH)) } ?? 1
        let scale = min(1, budget, edge)
        let width = max(1, Int(floor(Double(nativeW) * scale)))
        let height = max(1, Int(floor(Double(nativeH) * scale)))
        guard width * height <= maxPixels else { throw RAWDevelopmentError.invalidDimensions }

        // The sensor mosaic demosaics lazily into the requested bounded
        // image, not into a full-size UIImage/embedded camera preview.
        let normalized = raw.transformed(by: CGAffineTransform(
            translationX: -raw.extent.minX, y: -raw.extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(nativeW),
            y: CGFloat(height) / CGFloat(nativeH)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw RAWDevelopmentError.noColorSpace
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(InputSoftening.apply(scaled, amount: softness),
                           toBitmap: base, rowBytes: width * 4 * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: proPhoto)
        }
        let cg: CGImage? = preview
            ? context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                    colorSpace: proPhoto)
            : nil
        if preview && cg == nil { throw RAWDevelopmentError.failed }
        return Frame(pixels: rgba, width: width, height: height,
                     nativeWidth: nativeW, nativeHeight: nativeH, preview: cg)
    }
}
