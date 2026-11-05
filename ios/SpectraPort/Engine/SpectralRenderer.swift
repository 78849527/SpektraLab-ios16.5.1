import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UIKit

enum PortError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

struct RenderedPhoto {
    let original: UIImage
    let processed: UIImage
}

/// A serial queue owns the native engine/session lifetimes and keeps GPU work
/// off the main thread. This deliberately calls the upstream C ABI, not a LUT.
final class SpectralRenderer {
    private let queue = DispatchQueue(label: "com.twogou.spectralport.engine", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(data: Data, completion: @escaping (Result<RenderedPhoto, Error>) -> Void) {
        queue.async {
            let result = Result { try self.renderSynchronously(data) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func errorMessage(_ engine: OpaquePointer?) -> String {
        guard let text = spk_last_error(engine) else { return "unknown error" }
        return String(cString: text)
    }

    private func renderSynchronously(_ data: Data) throws -> RenderedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PortError.message("无法解码图片")
        }
        // iPhone memory budget: decode a small preview first. Do not hand the
        // engine a full-resolution 45MP RGBAf frame during interaction.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1440
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PortError.message("无法生成预览")
        }
        guard let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("系统缺少 ProPhoto RGB 色彩空间")
        }

        let width = thumbnail.width
        let height = thumbnail.height
        let input = CIImage(cgImage: thumbnail)
        var floats = [Float](repeating: 0, count: width * height * 4)
        try floats.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw PortError.message("图像内存分配失败")
            }
            context.render(
                input,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: proPhoto
            )
        }
        let original = UIImage(cgImage: thumbnail)

        // XcodeGen bundles the complete tracked engine/resources folder
        // beside the original Metal kernels, not a substitute colour profile.
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("spektrafilm_constants.bin").path) else {
            throw PortError.message("引擎资源未打包：engine/spektrafilm_constants.bin")
        }
        let native: OpaquePointer? = resources.path.withCString { spk_engine_create($0, nil) }
        guard let engine = native else {
            throw PortError.message("初始化失败：" + errorMessage(nil))
        }
        defer { spk_engine_destroy(engine) }

        var openReply: UnsafeMutablePointer<CChar>?
        defer { if let openReply { spk_string_free(openReply) } }

        let session: OpaquePointer? = floats.withUnsafeBufferPointer { buffer in
            var frame = spk_image(
                data: buffer.baseAddress,
                width: UInt32(width),
                height: UInt32(height),
                channels: 4
            )
            // Core Image handed us ProPhoto RGB pixels.
            let delta = "{\"input_color_space\":\"ProPhoto RGB\",\"input_cctf_decoding\":true}"
            return delta.withCString { spk_open(engine, &frame, $0, &openReply) }
        }
        guard let session else {
            throw PortError.message("打开帧失败：" + errorMessage(engine))
        }
        defer { spk_session_release(session) }

        var output = spk_result()
        let status = "live".withCString { spk_render(session, $0, &output) }
        guard status == SPK_OK else {
            throw PortError.message("渲染失败：" + errorMessage(engine))
        }
        defer { spk_result_free(&output) }

        guard let raw = output.rgba16, output.width > 0, output.height > 0 else {
            throw PortError.message("引擎没有返回像素")
        }
        // The result is gamma-encoded ProPhoto RGB RGBA16 with a padded row
        // stride. Copy before spk_result_free releases the Metal texture.
        let count = Int(output.row_stride_px) * Int(output.height) * 8
        let copied = Data(bytes: raw, count: count)
        guard let provider = CGDataProvider(data: copied as CFData) else {
            throw PortError.message("无法创建图像数据提供器")
        }
        let bitmap = CGBitmapInfo.byteOrder16Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let rendered = CGImage(
            width: Int(output.width),
            height: Int(output.height),
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: Int(output.row_stride_px) * 8,
            space: proPhoto,
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw PortError.message("无法从引擎结果创建 CGImage")
        }
        return RenderedPhoto(original: original, processed: UIImage(cgImage: rendered))
    }
}
