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
    let elapsedMS: Double
    let parametersVerified: Bool
}

/// The original spectral C ABI owns GPU textures, cached negatives and
/// source image planes. A single serial queue owns the native handles.
/// A print-only parameter change calls spk_reprint and reuses the negative;
/// a shoot-side change invalidates it via spk_set_params.
final class SpectralRenderer {
    private let queue = DispatchQueue(label: "com.twogou.spectralport.engine", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])

    private var engine: OpaquePointer?
    private var session: OpaquePointer?
    private var cachedPhotoID: UUID?
    private var cachedOriginal: UIImage?
    private var appliedSettings: FilmSettings?

    deinit {
        // Every enqueued render strongly retains this instance until its C
        // calls finish. Handle teardown runs only after those calls finish.
        if let session { spk_session_release(session) }
        if let engine { spk_engine_destroy(engine) }
    }

    func render(data: Data, photoID: UUID, settings: FilmSettings,
                completion: @escaping (Result<RenderedPhoto, Error>) -> Void) {
        queue.async {
            let result = Result {
                try self.renderSynchronously(data, photoID: photoID, settings: settings)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Pause normal preview work while exporting, and report real phase
    /// transitions rather than inventing percentages for an opaque GPU pass.
    func exportOriginal(
        data: Data,
        settings: FilmSettings,
        format: PreviewExporter.Format,
        limit: ExportLimit,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<HighResExportResult, Error>) -> Void
    ) {
        queue.async {
            let report: (String) -> Void = { phase in
                DispatchQueue.main.async { progress(phase) }
            }
            let outcome = Result {
                try self.exportSynchronously(data, settings: settings, format: format,
                                             limit: limit, report: report)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Release large native film session caches before opening UIKit camera.
    /// Runs on the same serial queue as all native C++ and Metal work.
    func suspendForCamera(completion: @escaping () -> Void) {
        queue.async {
            self.resetNativeState()
            DispatchQueue.main.async { completion() }
        }
    }

    private func resetNativeState() {
        if let session { spk_session_release(session) }
        session = nil
        if let engine { spk_engine_destroy(engine) }
        engine = nil
        cachedPhotoID = nil
        cachedOriginal = nil
        appliedSettings = nil
    }

    private func exportSynchronously(
        _ data: Data,
        settings: FilmSettings,
        format: PreviewExporter.Format,
        limit: ExportLimit,
        report: (String) -> Void
    ) throws -> HighResExportResult {
        // The preview's native caches can be large. Release them *before*
        // decoding the high-resolution frame. A later Apply opens preview
        // again, but the currently shown UIImage stays on screen.
        resetNativeState()
        defer { resetNativeState() }

        report("检查尺寸并解码原始照片…")
        var frame = try FullSizeExporter.decode(
            data, limit: limit, softness: settings.softness
        )
        report("初始化高清光谱会话…")
        let native = try ensureEngine()
        var openReply: UnsafeMutablePointer<CChar>?
        defer { if let openReply { spk_string_free(openReply) } }
        let delta = try settings.deltaJSON(striped: true)
        let opened: OpaquePointer? = frame.pixels.withUnsafeBufferPointer { buffer in
            var input = spk_image(
                data: buffer.baseAddress, width: UInt32(frame.width),
                height: UInt32(frame.height), channels: 4
            )
            return delta.withCString { spk_open(native, &input, $0, &openReply) }
        }
        // The native engine copied its source; release caller's float pixels
        // before film-development and print buffers are allocated.
        frame.pixels.removeAll(keepingCapacity: false)
        guard let opened else {
            throw PortError.message("高清会话打开失败：" + errorMessage(native))
        }
        defer { spk_session_release(opened) }

        report("原版 81 波长光谱引擎全尺寸渲染…")
        var output = spk_result()
        let code = "full".withCString { spk_render(opened, $0, &output) }
        guard code == SPK_OK else {
            throw PortError.message("高清光谱渲染失败：" + errorMessage(native))
        }
        defer { spk_result_free(&output) }

        report("转换 sRGB 并编码文件…")
        let url = try FullSizeExporter.write(output, format: format)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return HighResExportResult(
            url: url, fileFormat: format == .jpeg ? "JPEG" : "PNG", fileBytes: bytes,
            width: Int(output.width), height: Int(output.height),
            originalWidth: frame.nativeWidth, originalHeight: frame.nativeHeight,
            elapsedMS: output.elapsed_ms
        )
    }

    private func errorMessage(_ engine: OpaquePointer?) -> String {
        guard let text = spk_last_error(engine) else { return "unknown error" }
        return String(cString: text)
    }

    private func ensureEngine() throws -> OpaquePointer {
        if let engine { return engine }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("spektrafilm_constants.bin").path
              ) else {
            throw PortError.message("引擎资源未打包：engine/spektrafilm_constants.bin")
        }
        let created = resources.path.withCString { spk_engine_create($0, nil) }
        guard let created else {
            throw PortError.message("原版引擎初始化失败：" + errorMessage(nil))
        }
        engine = created
        return created
    }

    private func openPhoto(_ data: Data, photoID: UUID,
                           settings: FilmSettings, engine: OpaquePointer) throws {
        // The previous session's native buffers must be freed before opening
        // a differently sized photo. Engine kernels/tables survive the switch.
        if let session { spk_session_release(session) }
        session = nil
        cachedPhotoID = nil
        cachedOriginal = nil
        appliedSettings = nil

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PortError.message("无法解码图片")
        }
        // Keep the verified A15 preview memory budget, max edge 1440 px.
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
        let input = InputSoftening.apply(
            CIImage(cgImage: thumbnail), amount: settings.softness
        )
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

        var openReply: UnsafeMutablePointer<CChar>?
        defer { if let openReply { spk_string_free(openReply) } }
        let delta = try settings.deltaJSON()
        let opened: OpaquePointer? = floats.withUnsafeBufferPointer { buffer in
            var frame = spk_image(
                data: buffer.baseAddress,
                width: UInt32(width),
                height: UInt32(height),
                channels: 4
            )
            return delta.withCString { spk_open(engine, &frame, $0, &openReply) }
        }
        guard let opened else {
            throw PortError.message("打开光谱会话失败：" + errorMessage(engine))
        }
        session = opened
        cachedPhotoID = photoID
        cachedOriginal = UIImage(cgImage: thumbnail)
        appliedSettings = settings
    }

    /// Read back original C++ model settings instead of assuming the
    /// passed JSON is accepted solely because an image was produced.
    private func verifyResolvedParameters(
        _ session: OpaquePointer, settings: FilmSettings
    ) throws {
        var reply: UnsafeMutablePointer<CChar>?
        let code = spk_get_params(session, &reply)
        defer { if let reply { spk_string_free(reply) } }
        guard code == SPK_OK, let reply,
              let data = String(cString: reply).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let resolved = parsed as? [String: Any] else {
            throw PortError.message("引擎参数读回失败")
        }

        let stockValues = [
            "film_stock": settings.filmStock,
            "print_stock": settings.printStock
        ]
        for (key, expected) in stockValues {
            guard let actual = resolved[key] as? String, actual == expected else {
                throw PortError.message("引擎没有应用：" + key)
            }
        }
        guard let active = (resolved["halation_active"] as? NSNumber)?.boolValue,
              active == (settings.halationAmount > 0) else {
            throw PortError.message("光晕开关没有同步到原版引擎")
        }
        let numeric: [String: Double] = [
            "exposure_compensation_ev": settings.exposureEV,
            "grain_amount": settings.grainAmount,
            "halation_amount": settings.halationAmount,
            "print_exposure": settings.printExposure,
            "m_filter_shift": settings.magentaShift,
            "y_filter_shift": settings.yellowShift,
            "filter_shift_scale": 40.0
        ]
        for (key, expected) in numeric {
            guard let actual = (resolved[key] as? NSNumber)?.doubleValue,
                  abs(actual - expected) < 0.001 else {
                throw PortError.message("引擎读回参数与滑块不符：" + key)
            }
        }
    }

    private func renderSynchronously(_ data: Data, photoID: UUID,
                                     settings: FilmSettings) throws -> RenderedPhoto {
        let engine = try ensureEngine()
        if cachedPhotoID != photoID || session == nil ||
            appliedSettings?.softness != settings.softness {
            try openPhoto(data, photoID: photoID, settings: settings, engine: engine)
        } else if let previous = appliedSettings, previous != settings {
            // A print-only change reuses the existing film negative.
            // A film-side change automatically invalidates it upstream.
            let delta = try settings.changedDeltaJSON(from: previous)
            var reply: UnsafeMutablePointer<CChar>?
            defer { if let reply { spk_string_free(reply) } }
            guard let session else { throw PortError.message("会话已失效") }
            let code = delta.withCString { spk_set_params(session, $0, &reply) }
            guard code == SPK_OK else {
                throw PortError.message("设置参数失败：" + errorMessage(engine))
            }
            appliedSettings = settings
        }

        guard let session else { throw PortError.message("缺少光谱渲染会话") }
        try verifyResolvedParameters(session, settings: settings)
        var output = spk_result()
        // Unlike spk_render, reprint does not throw away a valid cached
        // negative. If shoot-side params changed, the engine generates one.
        let status = "live".withCString { spk_reprint(session, $0, &output) }
        guard status == SPK_OK else {
            throw PortError.message("原版光谱渲染失败：" + errorMessage(engine))
        }
        defer { spk_result_free(&output) }

        guard let raw = output.rgba16, output.width > 0, output.height > 0 else {
            throw PortError.message("引擎没有返回像素")
        }
        // Retain the original ProPhoto RGB / RGBA16 management of v0.2.1.
        // Copy the row-strided pixels before the native texture is released.
        let count = Int(output.row_stride_px) * Int(output.height) * 8
        let copied = Data(bytes: raw, count: count)
        guard let provider = CGDataProvider(data: copied as CFData) else {
            throw PortError.message("无法创建图像提供器")
        }
        guard let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("系统缺少 ProPhoto RGB 色彩空间")
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
            throw PortError.message("无法从光谱结果创建图片")
        }
        guard let original = cachedOriginal else {
            throw PortError.message("预览原图缓存丢失")
        }
        return RenderedPhoto(
            original: original,
            processed: UIImage(cgImage: rendered),
            elapsedMS: output.elapsed_ms,
            parametersVerified: true
        )
    }
}
