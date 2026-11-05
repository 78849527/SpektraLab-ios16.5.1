import CoreGraphics
import Foundation
import Metal

/// Executes the *unmodified* macOS Shaders.metal::layer2 kernel on the
/// spectral engine's encoded ProPhoto / ROMM print, before colour conversion.
///
/// This is intentionally separate from the C++ spectral engine and does not
/// substitute Core Image slider filters for desktop's Layer 2 arithmetic.
/// Global grading and five-channel curves are supported. The reference
/// macOS mask feature is disabled in that product; no local masks are
/// accepted by this first parity-stage adapter.
final class DesktopLayer2Processor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let emptyMaskBuffer: MTLBuffer
    private let emptyMaskRaster: MTLTexture
    private let dummyInputLUT: MTLTexture

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw PortError.message("桌面一致性调色层需要 Metal GPU")
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(
                    "engine/spectraport-desktop-layer2.metallib"),
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
        guard let maskBuffer = device.makeBuffer(length: 4096, options: .storageModeShared) else {
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

        let lutDesc = MTLTextureDescriptor.texture3DDescriptor(
            pixelFormat: .rgba16Float,
            width: 2, height: 2, depth: 2, mipmapped: false)
        lutDesc.usage = [.shaderRead]
        guard let lut = device.makeTexture(descriptor: lutDesc) else {
            throw PortError.message("分配 Layer 2 LUT 占位纹理失败")
        }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.emptyMaskBuffer = maskBuffer
        self.emptyMaskRaster = maskRaster
        self.dummyInputLUT = lut
    }

    /// Input: native engine RGBA16 little-endian ProPhoto RGB with explicit
    /// row stride. Output: an independent CGImage tagged with the same ROMM
    /// colour space. Do not mutate spk_result's borrowed/const pixel memory.
    ///
    /// This method is synchronous. Only call it on the spectral renderer's
    /// serial background queue, never on the main UI thread.
    func apply(
        raw: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        rowStridePixels: Int,
        adjustments: Adjustments
    ) throws -> CGImage {
        guard width > 0, height > 0, rowStridePixels >= width else {
            throw PortError.message("Layer 2 输入尺寸无效")
        }
        let bytesPerRow = rowStridePixels * MemoryLayout<UInt16>.stride * 4
        let length = bytesPerRow * height
        guard length > 0, length < 250_000_000 else {
            throw PortError.message("Layer 2 图像超出内存安全上限")
        }
        guard let romm = CGColorSpace(name: CGColorSpace.rommrgb) else {
            throw PortError.message("ROMM/ProPhoto 色彩空间不可用")
        }

        // Exactly neutral Layer 2 must preserve every source byte, avoiding
        // even one UNORM sample/quantization round-trip.
        if !adjustments.enabled || adjustments.isNeutral {
            let copy = Data(bytes: raw, count: length)
            return try makeImage(copy, width: width, height: height,
                                 bytesPerRow: bytesPerRow, colour: romm)
        }

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
        var maskCount: UInt32 = 0
        var maskOverlay: Int32 = -1
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        encoder.setTexture(curves, index: 2)
        encoder.setTexture(emptyMaskRaster, index: 3)
        encoder.setTexture(dummyInputLUT, index: 4)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 0)
        encoder.setBuffer(emptyMaskBuffer, offset: 0, index: 1)
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

        // The original output stride may be padded. The adjusted CGImage
        // uses tight rows; exporter and preview read the same bytes.
        let packedRow = width * 8
        var rendered = Data(count: packedRow * height)
        rendered.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                dst.getBytes(base, bytesPerRow: packedRow, from: region,
                             mipmapLevel: 0)
            }
        }
        return try makeImage(rendered, width: width, height: height,
                             bytesPerRow: packedRow, colour: romm)
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
