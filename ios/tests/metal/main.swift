import CoreGraphics
import ImageIO
import Foundation
import Metal

enum PortError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    if !ok() { fatalError("Desktop Layer2 pixel fixture FAILED: " + label) }
}
func channel(_ image: CGImage, _ x: Int, _ y: Int, _ component: Int) -> Double {
    guard let cf = image.dataProvider?.data, let bytes = CFDataGetBytePtr(cf) else {
        fatalError("Cannot inspect render pixels")
    }
    let offset = y * image.bytesPerRow + (x * 4 + component) * 2
    let low = UInt16(bytes[offset])
    let high = UInt16(bytes[offset + 1]) << 8
    return Double(low | high) / 65535
}

// GitHub's macOS runners may have no Metal device. In that case fail the
// *evidence of runtime support* explicitly in logs, but preserve separate
// source-compile tests. This is not falsely reported as GPU validation.
guard MTLCreateSystemDefaultDevice() != nil else {
    print("SKIPPED_GPU_RUNTIME: runner has no Metal device; true A15 validation pending")
    exit(0)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let processor = try DesktopLayer2Processor(libraryURL: url)
let width = 5
let height = 5
var input = [UInt16](repeating: 32768, count: width * height * 4)
for i in 0..<(width * height) { input[i * 4 + 3] = 65535 }

func render(_ grade: Adjustments, masks: [EditMask] = []) throws -> CGImage {
    try input.withUnsafeBufferPointer { buffer in
        guard let ptr = buffer.baseAddress else { fatalError("input missing") }
        return try processor.apply(
            raw: ptr, width: width, height: height,
            rowStridePixels: width, adjustments: grade, masks: masks)
    }
}

// Identity bypasses the GPU and must retain all 16-bit input values exactly.
let identity = try render(.default)
check(abs(channel(identity, 0, 0, 0) - Double(32768)/65535) < 1e-5,
      "neutral prints are byte-exact")

// Original shader exposure does a pseudo-linear 2.2 round-trip.
var exposure = Adjustments.default
exposure.exposure = 1
let brighter = try render(exposure)
let expected = pow(pow(Double(32768)/65535, 2.2) * 2, 1/2.2)
check(abs(channel(brighter, 0, 0, 0) - expected) < 0.015,
      "Mac exposure shader +1 EV")

var curveGrade = Adjustments.default
var curve = Curve.identity
curve.insert(CGPoint(x: 0.5, y: 0.7))
curveGrade.curves.red = curve
let red = try render(curveGrade)
check(channel(red, 2, 2, 0) > channel(red, 2, 2, 1) + 0.12,
      "Mac 5-row curve lookup acts on individual red channel")

// Local radial +1EV correction at centre should not brighten the corners.
var radial = EditMask.make(.radialGradient)
radial.adjustments.exposure = 1
let radialImage = try render(.default, masks: [radial])
check(channel(radialImage, 2, 2, 0) >
      channel(radialImage, 0, 0, 0) + 0.08,
      "Mac analytic radial local mask")

// A bottom-weighted linear gradient should alter the bottom of the frame.
var linear = EditMask.make(.linearGradient)
linear.adjustments.exposure = 1
let linearImage = try render(.default, masks: [linear])
check(channel(linearImage, 2, 4, 0) >
      channel(linearImage, 2, 0, 0) + 0.08,
      "Mac analytic linear local mask")

// Desktop split-zone colour balance master should push the selected channel.
var balance = Adjustments.default
balance.colorBalance.master.hue = 0
balance.colorBalance.master.saturation = 1
let colored = try render(balance)
check(channel(colored, 2, 2, 0) >
      channel(colored, 2, 2, 1) + 0.07,
      "Mac colour balance master red direction")


// Different source values make range-mask coverage provable, not merely
// a pass of "the image changed somewhere."
for y in 0..<height {
    for x in 0..<width {
        let v: UInt16 = x < 3 ? 13107 : 52428  // 0.2 / 0.8
        for k in 0..<3 { input[(y * width + x) * 4 + k] = v }
    }
}
var highRange = EditMask.make(.luminanceRange)
highRange.components[0].low = 0.55
highRange.components[0].high = 1
highRange.components[0].softness = 0.05
highRange.adjustments.exposure = 1
let lumaImage = try render(.default, masks: [highRange])
check(abs(channel(lumaImage, 0, 2, 0) - 0.2) < 0.02,
      "Mac luminance mask leaves dark pixels unchanged")
check(channel(lumaImage, 4, 2, 0) > 0.88,
      "Mac luminance mask targets bright pixels")

// A chroma-only selection is expressed in native ProPhoto values.
for y in 0..<height {
    for x in 0..<width {
        let source: [UInt16] = x < 3
            ? [49151, 22937, 19660] // ROMM .75/.35/.30
            : [29491, 29491, 29491] // neutral .45
        for k in 0..<3 { input[(y * width + x) * 4 + k] = source[k] }
    }
}
var chroma = EditMask.make(.colorRange)
chroma.components[0].color = SIMD3<Double>(0.75, 0.35, 0.3)
chroma.components[0].tolerance = 0.1
chroma.adjustments.exposure = 1
let colorMask = try render(.default, masks: [chroma])
check(channel(colorMask, 1, 2, 0) > 0.90,
      "Mac colour-range mask brightens matching chroma")
check(abs(channel(colorMask, 4, 2, 0) - 0.45) < 0.02,
      "Mac colour-range mask leaves dissimilar chroma unchanged")

// Restore a uniform 16-bit print, so a vignette and inversion can compare
// spatial coverage without unequal source pixels.
for y in 0..<height {
    for x in 0..<width {
        for k in 0..<3 { input[(y * width + x) * 4 + k] = 32768 }
    }
}
var vignette = Adjustments.default
vignette.vignette.amount = -85
let vignetted = try render(vignette)
check(channel(vignetted, 0, 0, 0) <
      channel(vignetted, 2, 2, 0) - 0.06,
      "Mac encoded-space vignette darkens corners")

var inverted = radial
inverted.inverted = true
let invertedImage = try render(.default, masks: [inverted])
check(channel(invertedImage, 0, 0, 0) >
      channel(invertedImage, 2, 2, 0) + 0.08,
      "Mac inverted radial mask reverses the affected region")

// The engine's native RGBA16 print may have padded rows. Assert neutral
// bypass honours that row stride rather than leaking padding into pixels.
let paddedRow = width + 2
var padded = [UInt16](repeating: 54321, count: paddedRow * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let d = (y * paddedRow + x) * 4
        let src = (y * width + x) * 4
        for k in 0..<4 { padded[d + k] = input[src + k] }
    }
}
let paddedImage = try padded.withUnsafeBufferPointer { buf in
    try processor.apply(
        raw: buf.baseAddress!, width: width, height: height,
        rowStridePixels: paddedRow, adjustments: .default)
}
check(abs(channel(paddedImage, 4, 4, 0) - Double(32768)/65535) < 1e-5,
      "native 16-bit padded row input bypass preserves source pixels")

print("METAL_GPU_FIXTURES_PASS: neutral, exposure, red curve, radial, linear, luminance, colour range, colour balance, vignette, inverse mask, padded rows")

// Exercise the actual new Build 21 GPU → CIImage → JPEG/PNG export path.
// Decoder dimensions and both images' central pixels must agree. Merely
// compiling CIImage(mtlTexture:) is insufficient: some GPU pixel formats
// are not supported until Core Image actually accesses their texture.
var exportGrade = Adjustments.default
exportGrade.exposure = 0.5
func verifiedExport(_ jpeg: Bool) throws -> CGImage {
    let url = try input.withUnsafeBufferPointer { pixels in
        try processor.export(
            raw: pixels.baseAddress!, width: width, height: height,
            rowStridePixels: width, adjustments: exportGrade,
            jpeg: jpeg)
    }
    defer { try? FileManager.default.removeItem(at: url) }
    check(url.pathExtension == (jpeg ? "jpg" : "png"),
          "encoded output extension")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Build 21 direct GPU export failed to decode")
    }
    check(image.width == width && image.height == height,
          "encoded image is not cropped or wrongly oriented")
    check(((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0,
          "encoded file is nonempty")
    return image
}
let jpegPhoto = try verifiedExport(true)
let pngPhoto = try verifiedExport(false)
// ImageIO decoder returns 8-bit sRGB here, whereas the source print is
// encoded 16-bit ProPhoto. Both encoders must agree within JPEG tolerance.
func meanCentralRGB(_ image: CGImage) -> SIMD3<Double> {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    defer { bytes.deallocate() }
    let info = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    guard let ctx = CGContext(
        data: bytes, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: cs, bitmapInfo: info.rawValue
    ) else { fatalError("JPEG/PNG test context unavailable") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let mid = (2 * width + 2) * 4
    return SIMD3<Double>(
        Double(bytes[mid]) / 255,
        Double(bytes[mid+1]) / 255,
        Double(bytes[mid+2]) / 255)
}
let jpgPixel = meanCentralRGB(jpegPhoto)
let pngPixel = meanCentralRGB(pngPhoto)
let channelDiffs = [
    abs(jpgPixel.x - pngPixel.x),
    abs(jpgPixel.y - pngPixel.y),
    abs(jpgPixel.z - pngPixel.z)
]
let diagnostic = "Build21 JPEG center \(jpgPixel); PNG center \(pngPixel); deltas \(channelDiffs)\n"
FileHandle.standardError.write(Data(diagnostic.utf8))
check(abs(jpgPixel.x - pngPixel.x) < 0.06 &&
      abs(jpgPixel.y - pngPixel.y) < 0.06 &&
      abs(jpgPixel.z - pngPixel.z) < 0.06,
      "Build 21 GPU JPEG/PNG encode agreement")
print("BUILD21_GPU_EXPORT_PASS: direct Metal texture → CIImage → JPEG/PNG")

// Real original-kernel pixel path at the two supported camera-size tiers.
// The runner is not the iPhone's thermal/memory environment; success is
// desktop GPU throughput/memory evidence, NOT iPhone validation.
func largeFrameFixture(_ w: Int, _ h: Int, processor: DesktopLayer2Processor) throws {
    // Manufacture a full 16-bit encoded ProPhoto print, including opaque alpha.
    // Avoid retaining the caller's pixels beyond the current fixture.
    var buffer = [UInt16](repeating: 32768, count: w * h * 4)
    for p in 0..<(w * h) { buffer[p * 4 + 3] = 65535 }
    var grade = Adjustments.default
    grade.exposure = 0.35
    let start = ProcessInfo.processInfo.systemUptime
    let picture = try buffer.withUnsafeBufferPointer { pixels in
        try processor.apply(
            raw: pixels.baseAddress!, width: w, height: h,
            rowStridePixels: w, adjustments: grade)
    }
    let millis = (ProcessInfo.processInfo.systemUptime - start) * 1000
    check(picture.width == w && picture.height == h,
          "full-tier graded dimensions \(w)x\(h)")
    check(picture.bytesPerRow == w * 8, "full-tier 16-bit output stride")
    check(channel(picture, w/2, h/2, 0) > 0.54,
          "full-tier GPU grade changes centre pixel")
    print("LARGE_METAL_FRAME_PASS: \(w)x\(h) · \(Int(millis)) ms GPU+readback")
}
try largeFrameFixture(2000, 3000, processor: processor)
try largeFrameFixture(3024, 4032, processor: processor)

// One JSON fixture from the actual *original* macOS Metal kernel can be
// compared against the Windows/WebGL-side TypeScript CPU implementation.
// All test pixels are encoded ProPhoto/ROMM, identical to what the iPhone
// port reads from the spectral print. A comparison cannot legitimately use
// Windows's sRGB mid-grey: specify 0.3857 for both platforms.
if CommandLine.arguments.count > 2 {
    let w = 4, h = 4
    var pixels = [UInt16](repeating: 65535, count: w * h * 4)
    var inputRGB = [Double]()
    for y in 0..<h {
        for x in 0..<w {
            let raw: [Double] = [
                0.28 + 0.10 * Double(x),
                0.20 + 0.09 * Double(y),
                0.35 + 0.035 * Double(x + y)
            ]
            for component in 0..<3 {
                let quantized = UInt16((raw[component] * 65535).rounded())
                pixels[(y * w + x) * 4 + component] = quantized
                inputRGB.append(Double(quantized) / 65535)
            }
        }
    }
    func metalCase(_ name: String, _ adjustments: Adjustments) throws -> [String: Any] {
        let cg = try pixels.withUnsafeBufferPointer { buffer in
            try processor.apply(
                raw: buffer.baseAddress!, width: w, height: h,
                rowStridePixels: w, adjustments: adjustments)
        }
        var output = [Double]()
        for y in 0..<h {
            for x in 0..<w {
                for k in 0..<3 { output.append(channel(cg, x, y, k)) }
            }
        }
        let codable = try JSONEncoder().encode(adjustments)
        let json = try JSONSerialization.jsonObject(with: codable)
        return [
            "name": name, "width": w, "height": h,
            "input": inputRGB, "output": output,
            "adjustments": json
        ]
    }
    var fixtures: [[String: Any]] = []
    fixtures.append(try metalCase("identity", .default))
    var exposure = Adjustments.default
    exposure.exposure = 0.8
    fixtures.append(try metalCase("exposure", exposure))
    var balance = Adjustments.default
    balance.temperature = 47
    balance.tint = -27
    balance.colorBalance.master.hue = 20
    balance.colorBalance.master.saturation = 0.6
    fixtures.append(try metalCase("white-balance-and-colour-wheel", balance))
    var tonal = Adjustments.default
    tonal.contrast = 18
    tonal.brightness = 11
    tonal.saturation = -15
    tonal.highlights = -35
    tonal.shadows = 26
    tonal.blackPoint = 3
    tonal.whitePoint = 4
    fixtures.append(try metalCase("tone-regions", tonal))
    var curved = Adjustments.default
    var redCurve = Curve.identity
    _ = redCurve.insert(CGPoint(x: 0.5, y: 0.7))
    curved.curves.red = redCurve
    fixtures.append(try metalCase("red-monotone-curve", curved))
    var vignette = Adjustments.default
    vignette.vignette.amount = -75
    vignette.vignette.midpoint = 40
    fixtures.append(try metalCase("vignette", vignette))
    var full = Adjustments.default
    full.exposure = 0.35
    full.temperature = 21
    full.contrast = 14
    full.highlights = -27
    full.shadows = 19
    full.colorBalance.shadows.hue = 240
    full.colorBalance.shadows.saturation = 0.35
    full.curves.red = redCurve
    full.vignette.amount = -23
    fixtures.append(try metalCase("combined-layer2", full))
    let serialized = try JSONSerialization.data(
        withJSONObject: ["workingSpace": "ROMM RGB", "midGrey": 0.3857,
                         "fixtures": fixtures],
        options: [.prettyPrinted, .sortedKeys])
    try serialized.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("MAC_METAL_GOLDEN_WRITTEN: \(fixtures.count) original shader pixel fixtures")
}


