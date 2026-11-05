import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// RAW is preserved as DNG. This is a Core Image scene developer for input to
/// the original negative/print engine, not feeding Bayer mosaics to spk_open.
enum RawImageDeveloper {
    static func developForSpectralEngine(
        dngURL: URL, pixelCeiling: Int
    ) throws -> Data {
        guard let raw = CIRAWFilter(imageURL: dngURL),
              let developed = raw.outputImage else {
            throw PortError.message("系统无法显影此 RAW/ProRAW 文件")
        }
        let bounds = developed.extent.integral
        guard bounds.width > 0, bounds.height > 0 else {
            throw PortError.message("RAW 像素尺寸无效")
        }
        let size = Double(bounds.width * bounds.height)
        let factor = min(1.0, sqrt(Double(pixelCeiling) / size) * 0.97)
        let image = factor < 1 ? developed.transformed(
            by: CGAffineTransform(scaleX: factor, y: factor)
        ) : developed
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PortError.message("缺少 sRGB 色彩空间")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-raw-developed-" + UUID().uuidString)
            .appendingPathExtension("jpg")
        let context = CIContext(options: [.cacheIntermediates: false])
        do {
            try context.writeJPEGRepresentation(
                of: image, to: outputURL, colorSpace: sRGB, options: [:]
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            return try Data(contentsOf: outputURL)
        } catch {
            throw PortError.message("RAW 本地显影失败：" + error.localizedDescription)
        }
    }
}
