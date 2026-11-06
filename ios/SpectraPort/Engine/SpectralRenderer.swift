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
    private var desktopLayer2: DesktopLayer2Processor?

    private struct CachedPrint {
        let pixels: Data
        let width: Int
        let height: Int
        let rowStridePixels: Int
    }
    private var cachedPrint: CachedPrint?

    private func imageFromCachedPrint(
        _ cache: CachedPrint, settings: FilmSettings
    ) throws -> CGImage {
        if needsDesktopLayer2(settings) {
            return try cache.pixels.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt16.self).baseAddress else {
                    throw PortError.message("印相缓存失效")
                }
                return try gradeProcessor().apply(
                    raw: base, width: cache.width, height: cache.height,
                    rowStridePixels: cache.rowStridePixels,
                    adjustments: settings.adjustments,
                    masks: settings.masks
                )
            }
        }

        guard let provider = CGDataProvider(data: cache.pixels as CFData),
              let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("原版印相缓存缺少 ProPhoto 颜色空间")
        }
        let bitmap = CGBitmapInfo.byteOrder16Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let output = CGImage(
            width: cache.width, height: cache.height,
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: cache.rowStridePixels * 8,
            space: proPhoto, bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else {
            throw PortError.message("无法从原版印相缓存生成图像")
        }
        return output
    }

    private func needsDesktopLayer2(_ settings: FilmSettings) -> Bool {
        (settings.adjustments.enabled && !settings.adjustments.isNeutral) ||
        settings.masks.contains { $0.enabled && !$0.isEmpty && $0.amount > 0 }
    }

    private func gradeProcessor() throws -> DesktopLayer2Processor {
        if let desktopLayer2 { return desktopLayer2 }
        let processor = try DesktopLayer2Processor()
        desktopLayer2 = processor
        return processor
    }

    deinit {
        // Every enqueued render strongly retains this instance until its C
        // calls finish. Handle teardown runs only after those calls finish.
        if let session { spk_session_release(session) }
        if let engine { spk_engine_destroy(engine) }
    }

    func render(data: Data, photoID: UUID, settings: FilmSettings,
                rawOptions: RAWDecodeOptions?,
                completion: @escaping (Result<RenderedPhoto, Error>) -> Void) {
        queue.async {
            let result = Result {
                try self.renderSynchronously(data, photoID: photoID, settings: settings,
                                             rawOptions: rawOptions)
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
        geometry: PhotoGeometry,
        rawOptions: RAWDecodeOptions?,
        filmEdge: MobileFilmEdgeSettings,
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
                                             geometry: geometry, rawOptions: rawOptions,
                                             filmEdge: filmEdge,
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
        cachedPrint = nil
        appliedSettings = nil
        desktopLayer2 = nil
    }

    private func exportSynchronously(
        _ data: Data,
        settings: FilmSettings,
        format: PreviewExporter.Format,
        geometry: PhotoGeometry,
        rawOptions: RAWDecodeOptions?,
        filmEdge: MobileFilmEdgeSettings,
        limit: ExportLimit,
        report: (String) -> Void
    ) throws -> HighResExportResult {
        // Beta safety gate: two 12.5MP RGBA16 textures, native spectral
        // buffers, readback and export staging can exceed the A15-class
        // working memory limit. Validate 6MP on device before 12.5MP.
        if needsDesktopLayer2(settings) && limit == .high {
            throw PortError.message(
                "调色测试版暂时仅支持安全档 6MP 导出。请在更多→导出中切换安全档，12.5MP 将在真机内存测试后开放。"
            )
        }

        // The preview's native caches can be large. Release them *before*
        // decoding the high-resolution frame. A later Apply opens preview
        // again, but the currently shown UIImage stays on screen.
        resetNativeState()
        defer { resetNativeState() }

        report("检查尺寸并解码原始照片…")
        var frame = try FullSizeExporter.decode(
            data, limit: limit, softness: settings.softness,
            rawOptions: rawOptions
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
        let url: URL
        if needsDesktopLayer2(settings) {
            guard let raw = output.rgba16 else {
                throw PortError.message("无法获取 Layer 2 原始印相像素")
            }
            report("应用 macOS 同源 Layer 2 调色与曲线…")
            let graded = try gradeProcessor().apply(
                raw: raw,
                width: Int(output.width),
                height: Int(output.height),
                rowStridePixels: Int(output.row_stride_px),
                adjustments: settings.adjustments,
                masks: settings.masks
            )
            url = try FullSizeExporter.write(graded, format: format, geometry: geometry)
        } else {
            // Identical to the original port when Layer 2 is neutral.
            url = try FullSizeExporter.write(output, format: format, geometry: geometry)
        }
        // Film edge is applied AFTER spectral print + desktop Layer2 + crop.
        // This is a distinct mobile compositor, not the Mac native overscan
        // physics path, and leaves source-local masks in their original UVs.
        let finishedURL: URL
        if filmEdge.needsComposite {
            report("生成片边、日期后背和签名…")
            finishedURL = try MobileFilmEdgeRenderer.export(
                sourceURL: url, settings: filmEdge,
                filmName: FilmCatalog.filmName(settings.filmStock),
                pixelLimit: limit.pixelLimit
            )
        } else {
            finishedURL = url
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: finishedURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard let imageSource = CGImageSourceCreateWithURL(finishedURL as CFURL, nil),
              let pixels = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                  as? [CFString: Any],
              let exportedWidth = (pixels[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let exportedHeight = (pixels[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw PortError.message("裁剪导出无法验证实际文件尺寸")
        }
        return HighResExportResult(
            url: finishedURL, fileFormat: format == .jpeg ? "JPEG" : "PNG", fileBytes: bytes,
            width: exportedWidth, height: exportedHeight,
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
                           settings: FilmSettings, rawOptions: RAWDecodeOptions?,
                           engine: OpaquePointer) throws {
        // The previous session's native buffers must be freed before opening
        // a differently sized photo. Engine kernels/tables survive the switch.
        if let session { spk_session_release(session) }
        session = nil
        cachedPhotoID = nil
        cachedOriginal = nil
        cachedPrint = nil
        appliedSettings = nil

        let width: Int
        let height: Int
        let thumbnail: CGImage
        var floats: [Float]

        if let rawOptions {
            // Sensor RAW must use the same Apple demosaic + WB as export.
            // The native spectral engine receives ProPhoto Float32 pixels;
            // embedded JPEG thumbnails never enter the calculation.
            let developed = try RawImageDeveloper.develop(
                data, options: rawOptions, maxPixels: 1440 * 1440,
                maxEdge: 1440, softness: settings.softness,
                context: context, preview: true
            )
            guard let rendered = developed.preview else {
                throw RAWDevelopmentError.failed
            }
            width = developed.width
            height = developed.height
            thumbnail = rendered
            floats = developed.pixels
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw PortError.message("无法解码图片")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else {
                throw PortError.message("无法生成预览")
            }
            guard let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
                throw PortError.message("系统缺少 ProPhoto RGB 色彩空间")
            }
            thumbnail = decoded
            width = decoded.width
            height = decoded.height
            let input = InputSoftening.apply(
                CIImage(cgImage: decoded), amount: settings.softness)
            floats = [Float](repeating: 0, count: width * height * 4)
            try floats.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw PortError.message("图像内存分配失败")
                }
                context.render(
                    input, toBitmap: base,
                    rowBytes: width * 4 * MemoryLayout<Float>.size,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBAf, colorSpace: proPhoto
                )
            }
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
                                     settings: FilmSettings,
                                     rawOptions: RAWDecodeOptions?) throws -> RenderedPhoto {
        // Curves, grading and masks are *after* the chemical/physical print.
        // Avoid recomputing the 81-wavelength negative/print when only Layer2
        // changed; preserve the exact RGBA16 print as a memory-bounded cache.
        if cachedPhotoID == photoID,
           let previous = appliedSettings,
           previous.samePhysicalPrint(as: settings),
           let cache = cachedPrint,
           let original = cachedOriginal {
            let start = ProcessInfo.processInfo.systemUptime
            let graded = try imageFromCachedPrint(cache, settings: settings)
            appliedSettings = settings
            return RenderedPhoto(
                original: original,
                processed: UIImage(cgImage: graded),
                elapsedMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                parametersVerified: true
            )
        }

        let engine = try ensureEngine()
        if cachedPhotoID != photoID || session == nil ||
            appliedSettings?.softness != settings.softness {
            try openPhoto(data, photoID: photoID, settings: settings,
                          rawOptions: rawOptions, engine: engine)
        } else if let previous = appliedSettings, previous != settings {
            // A print-only change reuses the existing film negative.
            // A film-side change automatically invalidates it upstream.
            let delta = try settings.changedDeltaJSON(from: previous)
            var reply: UnsafeMutablePointer<CChar>?
            defer { if let reply { spk_string_free(reply) } }
            guard let session else { throw PortError.message("会话已失效") }
            // A pure Layer 2 edit does not alter negative, enlarger or
            // paper parameters; skip the native parameter setter entirely.
            if delta != "{}" {
                let code = delta.withCString { spk_set_params(session, $0, &reply) }
                guard code == SPK_OK else {
                    throw PortError.message("设置参数失败：" + errorMessage(engine))
                }
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
        // Keep one immutable copy of the native ProPhoto print. The C ABI
        // spk_result's pointers are invalid after spk_result_free.
        guard output.row_stride_px >= output.width else {
            throw PortError.message("光谱印相缓存行跨度错误")
        }
        let count = Int(output.row_stride_px) * Int(output.height) * 8
        let copied = Data(bytes: raw, count: count)
        let cache = CachedPrint(
            pixels: copied,
            width: Int(output.width),
            height: Int(output.height),
            rowStridePixels: Int(output.row_stride_px)
        )
        cachedPrint = cache
        let rendered = try imageFromCachedPrint(cache, settings: settings)
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
