import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UIKit

/// Deliberate memory limits for the first A15 export build. This is not a
/// promise that any device can render 12 MP under arbitrary memory pressure.
enum ExportLimit: String, CaseIterable, Identifiable {
    case safe = "安全档 · 最多 6MP"
    case high = "高清档 · 最多 12.5MP"

    var id: String { rawValue }
    var pixelLimit: Int { self == .safe ? 6_000_000 : 12_500_000 }
}

struct HighResExportResult {
    let url: URL
    let fileFormat: String
    let fileBytes: Int64
    let width: Int
    let height: Int
    let originalWidth: Int
    let originalHeight: Int
    let elapsedMS: Double

    var reduced: Bool {
        Int64(width) * Int64(height) < Int64(originalWidth) * Int64(originalHeight)
    }

    var summary: String {
        let note = reduced ? "已按内存上限缩小" : "原始像素尺寸"
        let size = ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file)
        return "\(width) × \(height) · \(note) · \(fileFormat) \(size) · 光谱计算 \(String(format: "%.0f", elapsedMS)) ms"
    }
}

enum FullSizeExporter {
    struct DecodedFrame {
        var pixels: [Float]
        let width: Int
        let height: Int
        let nativeWidth: Int
        let nativeHeight: Int
    }

    /// Decode only after a metadata preflight, so a 48/100 MP source isn't
    /// accidentally decompressed at full resolution on a 4 GB iPhone.
    static func decode(_ data: Data, limit: ExportLimit, softness: Double = 0) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw PortError.message("无法获取照片原始尺寸")
        }
        let pixels = Int64(width) * Int64(height)
        guard pixels > 0 && pixels < Int64(1_000_000_000) else {
            throw PortError.message("原始照片尺寸异常，拒绝危险解码")
        }
        let fullEdge = max(width, height)
        // Leave headroom for ImageIO thumbnail rounding on rotated images.
        let factor = min(1.0, sqrt(Double(limit.pixelLimit) / Double(pixels)) * 0.975)
        let selectedEdge = max(64, Int(floor(Double(fullEdge) * factor)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: selectedEdge,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let first = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PortError.message("无法解码高清图片")
        }
        var picture = first
        let initialPixels = Int64(first.width) * Int64(first.height)
        if initialPixels > Int64(limit.pixelLimit) {
            // Some decoders return the whole image despite max thumb size.
            // Use a bounded CI downscale instead of failing the export.
            let ratio = sqrt(Double(limit.pixelLimit) * 0.94 / Double(initialPixels))
            let scaled = CIImage(cgImage: first).transformed(
                by: CGAffineTransform(scaleX: ratio, y: ratio)
            )
            let ci = CIContext(options: [.cacheIntermediates: false])
            guard let bounded = ci.createCGImage(scaled, from: scaled.extent) else {
                throw PortError.message("无法缩小至内存安全尺寸")
            }
            picture = bounded
        }
        let outW = picture.width
        let outH = picture.height
        let outPixels = Int64(outW) * Int64(outH)
        guard outPixels > 0 && outPixels <= Int64(limit.pixelLimit) else {
            throw PortError.message("解码像素超出安全上限")
        }
        guard let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("缺少 ProPhoto RGB")
        }
        // We allocate only the bounded 32-bit input. The film engine copies
        // this to its own Metal source, so the caller drops it immediately
        // after spk_open has returned.
        let ci = InputSoftening.apply(
            CIImage(cgImage: picture), amount: softness
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        var buffer = [Float](repeating: 0, count: outW * outH * 4)
        try buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw PortError.message("无法分配图像缓冲")
            }
            context.render(
                ci,
                toBitmap: base,
                rowBytes: outW * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                format: .RGBAf,
                colorSpace: proPhoto
            )
        }
        // Report the orientation-adjusted native shape for user comparison.
        let isRotated = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .map { [5, 6, 7, 8].contains($0.intValue) } ?? false
        return DecodedFrame(
            pixels: buffer, width: outW, height: outH,
            nativeWidth: isRotated ? height : width,
            nativeHeight: isRotated ? width : height
        )
    }

    /// The raw native RGBA16 storage is borrowed only until this synchronous
    /// encoder finishes. No full-resolution UIImage or extra RGBA16 copy.
    static func write(_ output: spk_result, format: PreviewExporter.Format) throws -> URL {
        guard let raw = output.rgba16, output.width > 0, output.height > 0,
              output.row_stride_px >= output.width else {
            throw PortError.message("光谱引擎未返回有效高清像素")
        }
        let length = Int(output.row_stride_px) * Int(output.height) * 8
        // Data owns neither the GPU buffer nor its lifetime. The caller must
        // keep spk_result alive until ImageIO/CoreImage is finished.
        let pixels = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: UnsafeRawPointer(raw)),
            count: length, deallocator: .none
        )
        guard let provider = CGDataProvider(data: pixels as CFData),
              let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PortError.message("无法创建高清色彩空间")
        }
        let bitmap = CGBitmapInfo.byteOrder16Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let picture = CGImage(
            width: Int(output.width), height: Int(output.height),
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: Int(output.row_stride_px) * 8,
            space: proPhoto, bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else {
            throw PortError.message("无法解释原版 RGBA16 输出")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-full-" + UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        let context = CIContext(options: [.cacheIntermediates: false])
        let image = CIImage(cgImage: picture)
        do {
            if format == .jpeg {
                try context.writeJPEGRepresentation(
                    of: image, to: url, colorSpace: sRGB,
                    options: [:]
                )
            } else {
                try context.writePNGRepresentation(
                    of: image, to: url, format: .RGBA8,
                    colorSpace: sRGB, options: [:]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw PortError.message("高清文件编码失败：" + error.localizedDescription)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw PortError.message("导出文件为空")
        }
        return url
    }
}
