import CoreGraphics
import CoreImage
import Foundation
import Metal

/// Executes the *unmodified* macOS Shaders.metal::layer2 kernel on the
/// spectral engine's encoded ProPhoto / ROMM print, before colour conversion.
///
/// This is intentionally separate from the C++ spectral engine and does not
/// substitute Core Image slider filters for desktop's Layer 2 arithmetic.
/// Global grading, five-channel curves and analytic desktop masks are
/// supported. The macOS UI currently hides masks, and brush rasters are
/// intentionally rejected here until a correct raster implementation exists.
final class DesktopLayer2Processor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let exportContext: CIContext
    private let emptyMaskBuffer: MTLBuffer
    private let emptyMaskRaster: MTLTexture
    private let dummyInputLUT: MTLTexture

    init(libraryURL: URL? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw PortError.message("桌面一致性调色层需要 Metal GPU")
        }
        let originalURL = Bundle.main.resourceURL?.appendingPathComponent(
            "engine/spectraport-desktop-layer2.metallib")
        guard let url = libraryURL ?? originalURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw PortError.message("未包含 macOS 原版 Layer 2 shader 资源")
        }
        let library = try device.makeLibrary(URL: url)
        guard let kernel = library.makeFunction(name: "layer2") else {
            throw PortError.message("原版 Metal Layer 2 kernel 不存在")
        }
        let pipeline = try device.makeComputePipelineState(function: kernel)

        // Shader bindings remain valid when maskCount == 0; the actual
        // disabled mask model is never emulated or silently turned on here.
        guard let maskBuffer = device.makeBuffer(
            length: MemoryLayout<MaskUniform>.stride, options: .storageModeShared) else {
            throw PortError.message("分配 Layer 2 蒙版空缓冲失败")
        }
        memset(maskBuffer.contents(), 0, maskBuffer.length)

        let rasters = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        rasters.textureType = .type2DArray
        rasters.arrayLength = 1
        rasters.usage = [.shaderRead]
        guard let maskRaster = device.makeTexture(descriptor: rasters) else {
            throw PortError.message("分配 Layer 2 空蒙版纹理失败")
        }

        // Metal Swift's MTLTextureDescriptor has no static 3-D factory.
        // Construct the descriptor explicitly for iOS 16.
        let lutDesc = MTLTextureDescriptor()
        lutDesc.textureType = .type3D
        lutDesc.pixelFormat = .rgba16Float
        lutDesc.width = 2
        lutDesc.height = 2
        lutDesc.depth = 2
        lutDesc.mipmapLevelCount = 1
        lutDesc.usage = [.shaderRead]
        guard let lut = device.makeTexture(descriptor: lutDesc) else {
            throw PortError.message("分配 Layer 2 LUT 占位纹理失败")
        }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.exportContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.emptyMaskBuffer = maskBuffer
        self.emptyMaskRaster = maskRaster
        self.dummyInputLUT = lut
    }

    /// Preview: preserve the existing CGImage / UIImage interface and
    /// neutral-path byte identity. This remains unchanged in Build 21.
    func apply(
        raw: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        rowStridePixels: Int,
        adjustments: Adjustments,
        masks: [EditMask] = []
    ) throws -> CGImage {
        let bytesPerRow = try validatedRowBytes(
            width: width, height: height, rowStridePixels: rowStridePixels)
        guard let romm = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("ROMM/ProPhoto 色彩空间不可用")
        }
        let activeMasks = try validatedMasks(masks)
        if (!adjustments.enabled || adjustments.isNeutral) && activeMasks.isEmpty {
            let copy = Data(bytes: raw, count: bytesPerRow * height)
            return try makeImage(copy, width: width, height: height,
                                 bytesPerRow: bytesPerRow, colour: romm)
        }
        let dst = try renderTexture(
            raw: raw, width: width, height: height,
            rowStridePixels: rowStridePixels, adjustments: adjustments,
            activeMasks: activeMasks)
        // Only previews read GPU pixels back into a CPU copy. The new
        // full-size export goes from the GPU texture straight to Core Image.
        let packedRow = width * 8
        var rendered = Data(count: packedRow * height)
        let region = MTLRegionMake2D(0, 0, width, height)
        rendered.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                dst.getBytes(base, bytesPerRow: packedRow,
                             from: region, mipmapLevel: 0)
            }
        }
        return try makeImage(rendered, width: width, height: height,
                             bytesPerRow: packedRow, colour: romm)
    }

    /// Full-resolution encoding: never call getBytes or manufacture an
    /// RGBA16 CGImage/UIImage. Core Image consumes the same device texture
    /// that the unmodified macOS Layer2 shader just produced.
    /// This avoids an extra 48MB (6MP) / 100MB (12.5MP) CPU pixel copy.
    func export(
        raw: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        rowStridePixels: Int,
        adjustments: Adjustments,
        masks: [EditMask] = [],
        jpeg: Bool
    ) throws -> URL {
        _ = try validatedRowBytes(
            width: width, height: height, rowStridePixels: rowStridePixels)
        let activeMasks = try validatedMasks(masks)
        guard let romm = CGColorSpace(name: CGColorSpace.rommrgb),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PortError.message("高清编码缺少 ProPhoto/sRGB 色彩空间")
        }
        // Purely neutral settings should use the spectral encoder's existing
        // bypass instead of this GPU export entrypoint.
        guard (adjustments.enabled && !adjustments.isNeutral) ||
              !activeMasks.isEmpty else {
            throw PortError.message("中性调色请使用原版光谱高清导出路径")
        }
        let dst = try renderTexture(
            raw: raw, width: width, height: height,
            rowStridePixels: rowStridePixels, adjustments: adjustments,
            activeMasks: activeMasks)
        guard let sampled = CIImage(
            mtlTexture: dst, options: [.colorSpace: romm]
        ) else {
            throw PortError.message("无法将 Metal 输出纹理交给 Core Image")
        }
        // Source photographs and the untouched desktop Metal layer2 shader
        // are fully opaque. Core Image's Metal-texture adaptor can report
        // alpha=0 when encoding PNG, despite the shader writing float4(c,1).
        // JPEG drops alpha and hid this bug. Enforce the known-opaque
        // contract *on the GPU*, before either image encoder receives it.
        // This prevents transparent-black PNGs with no RGBA16 CPU readback.
        let image = sampled.settingAlphaOne(in: sampled.extent)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpectraPort-layer2-GPU-" + UUID().uuidString)
            .appendingPathExtension(jpeg ? "jpg" : "png")
        do {
            if jpeg {
                try exportContext.writeJPEGRepresentation(
                    of: image, to: url, colorSpace: srgb, options: [:])
            } else {
                try exportContext.writePNGRepresentation(
                    of: image, to: url, format: .RGBA8,
                    colorSpace: srgb, options: [:])
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw PortError.message(
                "Metal 直连高清导出失败：" + error.localizedDescription)
        }
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw PortError.message("Metal 直连高清导出的文件为空")
        }
        return url
    }

    private func validatedRowBytes(
        width: Int, height: Int, rowStridePixels: Int
    ) throws -> Int {
        guard width > 0, height > 0, rowStridePixels >= width,
              rowStridePixels <= Int.max / 8,
              height <= Int.max / (rowStridePixels * 8) else {
            throw PortError.message("Layer 2 输入尺寸或行跨度无效")
        }
        let bytesPerRow = rowStridePixels * 8
        let length = bytesPerRow * height
        guard length > 0, length < 250_000_000 else {
            throw PortError.message("Layer 2 图像超出内存安全上限")
        }
        return bytesPerRow
    }

    private func validatedMasks(_ masks: [EditMask]) throws -> [EditMask] {
        let active = masks.filter { $0.enabled && !$0.isEmpty && $0.amount > 0 }
        guard active.count <= EditMask.maxCount else {
            throw PortError.message("局部蒙版超出原版最多 8 个的限制")
        }
        guard active.allSatisfy({
            $0.components.count <= EditMask.maxComponents
        }) else {
            throw PortError.message("单个局部蒙版超出最多 6 个形状的限制")
        }
        guard !active.contains(where: { $0.needsRaster }) else {
            throw PortError.message("画笔蒙版需要笔刷纹理，当前版本暂未开放")
        }
        return active
    }

    /// The exact macOS Layer2 Metal kernel. Preview and export call it
    /// with the same uniform layout, curves and analytic mask buffers.
    private func renderTexture(
        raw: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        rowStridePixels: Int,
        adjustments: Adjustments,
        activeMasks: [EditMask]
    ) throws -> MTLTexture {
        let bytesPerRow = try validatedRowBytes(
            width: width, height: height, rowStridePixels: rowStridePixels)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: width, height: height,
            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let src = device.makeTexture(descriptor: desc),
              let dst = device.makeTexture(descriptor: desc) else {
            throw PortError.message("Layer 2 分配 GPU 纹理失败")
        }
        let region = MTLRegionMake2D(0, 0, width, height)
        src.replace(region: region, mipmapLevel: 0, withBytes: raw,
                    bytesPerRow: bytesPerRow)

        let curveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: Curve.tableSize,
            height: CurveChannel.allCases.count, mipmapped: false)
        curveDesc.usage = [.shaderRead]
        guard let curves = device.makeTexture(descriptor: curveDesc) else {
            throw PortError.message("无法分配五通道曲线查找表")
        }
        let values = adjustments.curves.tables()
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            curves.replace(
                region: MTLRegionMake2D(0, 0, Curve.tableSize,
                                        CurveChannel.allCases.count),
                mipmapLevel: 0, withBytes: base,
                bytesPerRow: Curve.tableSize * MemoryLayout<Float>.stride)
        }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeComputeCommandEncoder() else {
            throw PortError.message("无法建立 Layer 2 Metal 计算命令")
        }
        var u = adjustments.uniforms
        let packedMasks = activeMasks.map { $0.uniform() }
        var maskCount = UInt32(packedMasks.count)
        var maskOverlay: Int32 = -1
        let maskBytes = packedMasks.count * MemoryLayout<MaskUniform>.stride
        let masksGPU: MTLBuffer?
        if packedMasks.isEmpty {
            masksGPU = nil
        } else {
            masksGPU = packedMasks.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: ptr, length: maskBytes, options: .storageModeShared)
            }
            guard masksGPU != nil else {
                throw PortError.message("局部蒙版 GPU 参数缓冲分配失败")
            }
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        encoder.setTexture(curves, index: 2)
        encoder.setTexture(emptyMaskRaster, index: 3)
        encoder.setTexture(dummyInputLUT, index: 4)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 0)
        encoder.setBuffer(masksGPU ?? emptyMaskBuffer, offset: 0, index: 1)
        encoder.setBytes(&maskCount, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.setBytes(&maskOverlay, length: MemoryLayout<Int32>.size, index: 3)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: group)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else {
            throw PortError.message("macOS Layer 2 GPU 调色失败：" +
                (cmd.error?.localizedDescription ?? "unknown Metal error"))
        }

        return dst
    }

    private func makeImage(_ pixels: Data, width: Int, height: Int,
                           bytesPerRow: Int, colour: CGColorSpace) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw PortError.message("Layer 2 无法建立图像缓冲提供器")
        }
        let bitmap = CGBitmapInfo.byteOrder16Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let output = CGImage(
            width: width, height: height,
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: bytesPerRow, space: colour,
            bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: true,
            intent: .defaultIntent) else {
            throw PortError.message("Layer 2 输出图片格式不可用")
        }
        return output
    }
}
