import CoreGraphics
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

