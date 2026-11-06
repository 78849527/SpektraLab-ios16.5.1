import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

/// RAW sensor decoding ahead of the original SpektraLab spectral engine.
/// The Mac's linear CIRAWFilter look is used: no boost, no local tone map.
/// Never silently use an embedded camera JPEG in place of RAW pixels.
enum RAWDecoderBackend: Equatable { case coreImage, libRaw }

struct RAWDecodeOptions: Equatable {
    var identifierHint: String?
    var useAsShot = true
    var temperature: Double = 5500
    var tint: Double = 0
    var lensCorrection = true
    var decoder: RAWDecoderBackend = .coreImage

    var safeTemperature: Float { Float(max(2000, min(50000, temperature))) }
    var safeTint: Float { Float(max(-150, min(150, tint))) }
}
struct RAWProbe {
    let temperature: Double
    let tint: Double
    let lensCorrectionSupported: Bool
    let width: Int
    let height: Int
    var decoder: RAWDecoderBackend = .coreImage
}
enum RAWDevelopmentError: LocalizedError {
    case unsupported, unsafeFileSize, invalidDimensions, failed, noColorSpace, decoderMessage(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: "iOS 没有此相机 RAW 的传感器解码器，已拒绝内嵌 JPEG 替代"
        case .unsafeFileSize: "RAW 文件超过 180 MB 的安全限制"
        case .invalidDimensions: "RAW 原始尺寸异常"
        case .failed: "RAW 显影失败，可能是文件损坏或相机型号不受支持"
        case .noColorSpace: "设备缺少 ProPhoto 工作色彩空间"
        case let .decoderMessage(message): message
        }
    }
}

enum RawImageDeveloper {
    static let rawExtensions: Set<String> =
        ["raf", "dng", "nef", "arw", "cr2", "cr3", "rw2", "orf", "pef", "srw", "3fr", "iiq"]

    /// Copy the Mac ImageDecoder.linearProPhoto profile exactly. The native
    /// film engine receives linear D50 ProPhoto, not gamma-encoded ROMM.
    private static let linearProPhoto: CGColorSpace? = {
        let white: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100
        ]
        return white.withUnsafeBufferPointer { w in
            black.withUnsafeBufferPointer { b in
                gamma.withUnsafeBufferPointer { g in
                    primaries.withUnsafeBufferPointer { m in
                        CGColorSpace(calibratedRGBWhitePoint: w.baseAddress!,
                                     blackPoint: b.baseAddress,
                                     gamma: g.baseAddress!, matrix: m.baseAddress)
                    }
                }
            }
        }
    }()


    static func isRaw(filename: String, typeID: String? = nil) -> Bool {
        if rawExtensions.contains((filename as NSString).pathExtension.lowercased()) { return true }
        guard let typeID, let type = UTType(typeID) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Read Files/iCloud provider URLs while the security scope is active and
    /// coordinated. Direct Data(contentsOf:) can fail for provider-managed
    /// files that have not been materialized in the app's process yet.
    static func readFile(at url: URL) throws -> Data {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            readResult = Result {
                try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw RAWDevelopmentError.failed }
        return try readResult.get()
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

    static func probe(_ data: Data, hint: String?,
                      filename: String? = nil) throws -> RAWProbe {
        // iOS 16 does not decode every compressed Fujifilm RAF variant.
        // Route RAF through the same pinned LibRaw decoder as the desktop app.
        let isFujiRAF = filename.map { ($0 as NSString).pathExtension.lowercased() == "raf" } ?? false
        if !isFujiRAF,
           let f = try? filter(data, options: RAWDecodeOptions(identifierHint: hint)),
           let image = f.outputImage {
            let w = image.extent.width, h = image.extent.height
            if w >= 64, h >= 64, w.isFinite, h.isFinite, w*h < 1_000_000_000 {
                return RAWProbe(temperature: Double(f.neutralTemperature),
                                tint: Double(f.neutralTint),
                                lensCorrectionSupported: f.isLensCorrectionSupported,
                                width: Int(w), height: Int(h), decoder: .coreImage)
            }
        }
        let dimensions = try libRawProbe(data)
        return RAWProbe(temperature: 5500, tint: 0,
                        lensCorrectionSupported: false,
                        width: dimensions.width, height: dimensions.height,
                        decoder: .libRaw)
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
        if options.decoder == .libRaw {
            return try developWithLibRaw(data, maxPixels: maxPixels, maxEdge: maxEdge,
                                         softness: softness, context: context, preview: preview)
        }
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
        guard let linear = linearProPhoto,
              let proPhotoDisplay = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw RAWDevelopmentError.noColorSpace
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(InputSoftening.apply(scaled, amount: softness),
                           toBitmap: base, rowBytes: width * 4 * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: linear)
        }
        let cg: CGImage? = preview
            ? context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                    colorSpace: proPhotoDisplay)
            : nil
        if preview && cg == nil { throw RAWDevelopmentError.failed }
        return Frame(pixels: rgba, width: width, height: height,
                     nativeWidth: nativeW, nativeHeight: nativeH, preview: cg)
    }

    private static func withTemporaryRAF<T>(_ data: Data,
                                             _ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-\\(UUID().uuidString).raf")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private static func bridgeError(_ buffer: UnsafeMutablePointer<CChar>) -> String {
        let message = String(cString: buffer)
        return message.isEmpty ? "应用内 RAF 解码失败。" : message
    }

    private static func libRawProbe(_ data: Data) throws -> (width: Int, height: Int) {
        try withTemporaryRAF(data) { url in
            let error = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
            error.initialize(repeating: 0, count: 1024)
            defer { error.deinitialize(count: 1024); error.deallocate() }
            var width: UInt32 = 0, height: UInt32 = 0
            let success = url.path.withCString {
                spk_raw_probe_file($0, &width, &height, error, 1024)
            }
            guard success != 0 else {
                throw RAWDevelopmentError.decoderMessage(bridgeError(error))
            }
            return (Int(width), Int(height))
        }
    }

    private static func developWithLibRaw(_ data: Data, maxPixels: Int,
                                          maxEdge: Int?, softness: Double,
                                          context: CIContext, preview: Bool) throws -> Frame {
        guard data.count <= 180_000_000, maxPixels > 0 else {
            throw RAWDevelopmentError.unsafeFileSize
        }
        guard let linear = linearProPhoto,
              let displaySpace = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw RAWDevelopmentError.noColorSpace
        }
        return try withTemporaryRAF(data) { url in
            let error = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
            error.initialize(repeating: 0, count: 1024)
            defer { error.deinitialize(count: 1024); error.deallocate() }
            var decoded: UnsafeMutablePointer<Float>?
            var width: UInt32 = 0, height: UInt32 = 0
            var nativeWidth: UInt32 = 0, nativeHeight: UInt32 = 0
            let success = url.path.withCString {
                spk_raw_decode_file($0, preview ? 1 : 0, &decoded,
                                    &width, &height, &nativeWidth, &nativeHeight,
                                    error, 1024)
            }
            guard success != 0, let decoded else {
                throw RAWDevelopmentError.decoderMessage(bridgeError(error))
            }
            defer { spk_raw_free_buffer(decoded) }
            let w = Int(width), h = Int(height)
            guard w >= 64, h >= 64, Int64(w) * Int64(h) < 1_000_000_000 else {
                throw RAWDevelopmentError.invalidDimensions
            }
            let sampleCount = w * h * 3
            let rgb = Array(UnsafeBufferPointer(start: decoded, count: sampleCount))
            let pixelCount = w * h
            var rgba = [Float](repeating: 1, count: pixelCount * 4)
            for index in 0..<pixelCount {
                rgba[index * 4] = rgb[index * 3]
                rgba[index * 4 + 1] = rgb[index * 3 + 1]
                rgba[index * 4 + 2] = rgb[index * 3 + 2]
            }
            let bitmap = rgba.withUnsafeBytes { Data($0) }
            guard let rawImage = CIImage(bitmapData: bitmap, bytesPerRow: w * 16,
                                         size: CGSize(width: w, height: h),
                                         format: .RGBAf, colorSpace: linear) else {
                throw RAWDevelopmentError.failed
            }
            let nativeW = Int(nativeWidth), nativeH = Int(nativeHeight)
            let budget = sqrt(Double(maxPixels) * 0.94 / Double(w * h))
            let edge = maxEdge.map { Double($0) / Double(max(w, h)) } ?? 1
            let scale = min(1, budget, edge)
            let outW = max(1, Int(floor(Double(w) * scale)))
            let outH = max(1, Int(floor(Double(h) * scale)))
            let normalized = rawImage.transformed(by: CGAffineTransform(
                translationX: -rawImage.extent.minX, y: -rawImage.extent.minY))
            let scaled = normalized.transformed(by: CGAffineTransform(
                scaleX: CGFloat(outW) / CGFloat(w), y: CGFloat(outH) / CGFloat(h)))
                .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
            var output = [Float](repeating: 0, count: outW * outH * 4)
            output.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                context.render(InputSoftening.apply(scaled, amount: softness),
                               toBitmap: base, rowBytes: outW * 16,
                               bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                               format: .RGBAf, colorSpace: linear)
            }
            let cg = preview
                ? context.createCGImage(scaled, from: scaled.extent,
                                        format: .RGBA8, colorSpace: displaySpace)
                : nil
            if preview && cg == nil { throw RAWDevelopmentError.failed }
            return Frame(pixels: output, width: outW, height: outH,
                         nativeWidth: nativeW, nativeHeight: nativeH, preview: cg)
        }
    }
}
