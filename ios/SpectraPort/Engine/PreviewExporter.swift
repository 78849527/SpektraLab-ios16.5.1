import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Export exactly the rendered preview; this is not a full-resolution export.
enum PreviewExporter {
    enum Format {
        case jpeg, png
        var fileExtension: String { self == .jpeg ? "jpg" : "png" }
        var contentType: UTType { self == .jpeg ? .jpeg : .png }
    }

    static func write(_ image: UIImage, format: Format) throws -> URL {
        guard let source = image.cgImage,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PortError.message("没有可导出的图像或 sRGB 色彩空间")
        }
        // The render engine returns a ProPhoto RGB CGImage. Explicitly
        // transform it to sRGB for common JPEG/PNG viewers and social apps.
        let ciImage = CIImage(cgImage: source)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let converted = context.createCGImage(
            ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: sRGB
        ) else {
            throw PortError.message("预览图转换为 sRGB 失败")
        }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-preview-" + UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, format.contentType.identifier as CFString, 1, nil
        ) else {
            throw PortError.message("无法建立输出文件")
        }

        if format == .jpeg {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.93]
            CGImageDestinationAddImage(destination, converted, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, converted, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw PortError.message("无法写入输出图片")
        }
        return target
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct PreviewShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
