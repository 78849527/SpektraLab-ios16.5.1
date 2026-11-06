import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Phase 1 mobile Film Edge compositor. Matches the Mac's ten physical gate
/// dimensions and strip/filed presentation, but is intentionally NOT the
/// original spectral engine's RFC-032 emulsion-exposed overscan. That engine
/// integration requires crop-before-negative and mask-coordinate migration.
enum MobileFilmEdgeRenderer {
    enum Failure: LocalizedError {
        case invalidImage, renderFailed, encodeFailed
        var errorDescription: String? {
            switch self {
            case .invalidImage: "胶片片边没有有效的照片像素"
            case .renderFailed: "胶片片边生成失败"
            case .encodeFailed: "胶片片边编码失败"
            }
        }
    }

    static func preview(_ image: UIImage, settings: MobileFilmEdgeSettings,
                        filmName: String) throws -> UIImage {
        guard settings.enabled, let cg = image.cgImage else { return image }
        return try UIImage(cgImage: render(
            cg, settings: settings, filmName: filmName,
            pixelLimit: 2_000_000))
    }

    static func export(sourceURL: URL, settings: MobileFilmEdgeSettings,
                       filmName: String, pixelLimit: Int) throws -> URL {
        guard settings.enabled else { return sourceURL }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            throw Failure.invalidImage
        }
        let output = try render(
            cg, settings: settings, filmName: filmName,
            pixelLimit: pixelLimit)
        let ext = sourceURL.pathExtension.lowercased()
        let typeID = ext == "png" ? UTType.png.identifier : UTType.jpeg.identifier
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-film-edge-" + UUID().uuidString)
            .appendingPathExtension(ext == "png" ? "png" : "jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, typeID as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.94
        ]
        CGImageDestinationAddImage(
            destination, output,
            ext == "png" ? nil : props as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              (try? target.resourceValues(
                forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            try? FileManager.default.removeItem(at: target)
            throw Failure.encodeFailed
        }
        // File move only after a complete, nonempty successor exists.
        // All callers (preview high-res, share, JPEG/PNG, PhotoKit) use target.
        try? FileManager.default.removeItem(at: sourceURL)
        return target
    }

    private static func render(_ source: CGImage,
                               settings: MobileFilmEdgeSettings,
                               filmName: String, pixelLimit: Int) throws -> CGImage {
        guard let layout = MobileFilmEdgeLayout.make(
            image: CGSize(width: source.width, height: source.height),
            settings: settings, pixelLimit: pixelLimit
        ) else { throw Failure.invalidImage }
        let settings = settings.normalized()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: layout.canvas, format: format
        ).image { surface in
            let context = surface.cgContext
            context.setFillColor(UIColor(
                red: 0.055, green: 0.052, blue: 0.049, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: layout.canvas))
            if settings.view == .filed {
                context.setFillColor(UIColor(
                    red: 0.15, green: 0.15, blue: 0.14, alpha: 1).cgColor)
                context.fill(CGRect(origin: .zero, size: layout.canvas))
            }
            let fog = CGFloat(settings.fog)
            context.setFillColor(UIColor(
                red: 0.046 + fog*0.020, green: 0.030 + fog*0.014,
                blue: 0.021 + fog*0.007, alpha: 1).cgColor)
            context.fill(layout.filmRect)

            let gate = UIBezierPath(
                roundedRect: layout.gateRect,
                cornerRadius: max(1, layout.gateRect.height*0.0025))
            context.saveGState()
            gate.addClip()
            let sourceSize = CGSize(width: source.width, height: source.height)
            let scale = max(layout.gateRect.width/sourceSize.width,
                            layout.gateRect.height/sourceSize.height)
            let drawn = CGSize(width: sourceSize.width*scale,
                               height: sourceSize.height*scale)
            // Aspect-fill inside the physical gate, equal on preview/export.
            // The image itself is never destructively re-cropped in the model.
            UIImage(cgImage: source).draw(in: CGRect(
                x: layout.gateRect.midX - drawn.width/2,
                y: layout.gateRect.midY - drawn.height/2,
                width: drawn.width, height: drawn.height
            ))
            context.restoreGState()

            context.setStrokeColor(UIColor(
                red: 0.36, green: 0.24, blue: 0.15, alpha: 0.6).cgColor)
            context.setLineWidth(max(0.6, layout.gateRect.width*0.0007))
            context.addPath(gate.cgPath)
            context.strokePath()

            let holeColor: UIColor = settings.holes == .white
                ? UIColor(white: 0.94, alpha: 1)
                : UIColor(white: 0.012, alpha: 1)
            context.setFillColor(holeColor.cgColor)
            for hole in layout.holes {
                let path = UIBezierPath(
                    roundedRect: hole,
                    cornerRadius: min(hole.width,hole.height)*0.24)
                context.addPath(path.cgPath)
                context.fillPath()
            }

            drawEdgeText(layout: layout, settings: settings, filmName: filmName)
            if settings.leaks > 0 {
                addWarmLeak(context: context, layout: layout,
                            strength: CGFloat(settings.leaks))
            }
        }
        guard let cg = image.cgImage else { throw Failure.renderFailed }
        return cg
    }

    private static func drawEdgeText(layout: MobileFilmEdgeLayout,
                                     settings: MobileFilmEdgeSettings,
                                     filmName: String) {
        let original = settings.edgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stock = original.isEmpty ? filmName : original
        let line = "\(stock.uppercased())   \(String(format:"%02d",settings.frameNumber))"
        let typography = min(
            max(7, layout.gateRect.height*0.0125),
            max(7, layout.edgeLabelRect.height * 0.58)
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(
                ofSize: typography, weight: .medium),
            .foregroundColor: UIColor(
                red: 0.93, green: 0.70, blue: 0.34, alpha: 0.8)
        ]
        let text = line as NSString
        if layout.isPortrait {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.saveGState()
            ctx.translateBy(x: layout.edgeLabelRect.maxX,
                            y: layout.edgeLabelRect.minY)
            ctx.rotate(by: .pi/2)
            text.draw(in: CGRect(
                x: 0, y: 0,
                width: layout.edgeLabelRect.height,
                height: layout.edgeLabelRect.width
            ), withAttributes: attrs)
            ctx.restoreGState()
        } else {
            text.draw(in: layout.edgeLabelRect, withAttributes: attrs)
        }
    }

    private static func addWarmLeak(context: CGContext,
                                    layout: MobileFilmEdgeLayout,
                                    strength: CGFloat) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: [
                UIColor(red: 1,green:0.19,blue:0.04,
                        alpha: min(0.55,strength*0.10)).cgColor,
                UIColor(red: 1,green:0.1,blue:0.03,alpha:0).cgColor
              ] as CFArray, locations: [0,1]) else { return }
        context.saveGState()
        context.clip(to: layout.filmRect)
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: layout.filmRect.minX,
                                 y: layout.filmRect.midY),
            startRadius: 0,
            endCenter: CGPoint(x: layout.filmRect.minX,
                               y: layout.filmRect.midY),
            endRadius: max(layout.filmRect.width,
                           layout.filmRect.height)*0.52,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}
