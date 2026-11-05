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

print("METAL_GPU_FIXTURES_PASS: neutral, exposure, red curve, radial, linear, color balance")
