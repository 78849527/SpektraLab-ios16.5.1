import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("Layer2 model mismatch: " + message) }
}
func close(_ a: Double, _ b: Double, eps: Double = 0.00001) -> Bool {
    abs(a - b) < eps
}

// Exact Mac CurveMath behaviour.
let identity = Curve.identity
expect(identity.isIdentity, "curve identity flag")
for n in 0...10 {
    let x = CGFloat(n) / 10
    expect(close(Double(identity.evaluate(x)), Double(x)), "identity at \(n)")
}
var c = Curve.identity
_ = c.insert(CGPoint(x: 0.5, y: 0.7))
expect(close(Double(c.evaluate(0.5)), 0.7), "interpolation passes through mid-point")
expect(c.points.count == 3, "control point count")
c.move(1, to: CGPoint(x: 0.9, y: 0.75))
expect(c.points[1].x < c.points[2].x, "endpoint order")
var curves = CurveSet()
curves.red = c
let table = curves.tables()
expect(table.count == 256 * 5, "five 256-sample table rows")
expect(close(Double(table[128]), 128.0/255.0, eps: 0.005), "master identity row")
expect(close(Double(table[256+128]), 128.0/255.0, eps: 0.005), "luma identity row")
expect(!curves.isIdentity, "nonidentity red curve")

// Mac Layer2 defaults and the shared Mask.swift tone packing.
let neutral = Adjustments.default
expect(neutral.isNeutral, "neutral adjustment defaults")
expect(close(Double(neutral.uniforms.exposureGain), 1), "neutral exposure")
expect(close(Double(neutral.uniforms.midGrey), 0.3857), "ROMM working-space pivot")
var exposure = Adjustments()
exposure.exposure = 1
expect(close(Double(exposure.uniforms.exposureGain), 2), "one-stop increase")
exposure.temperature = 100
expect(close(Double(exposure.uniforms.wbGain.x), 1.18, eps: 0.0001),
       "Mac white-balance gain")
expect(close(Double(exposure.uniforms.wbGain.z), 0.82, eps: 0.0001),
       "Mac white-balance inverse")
print("Verified: Mac CurveMath, 5x256 LUT, Mac Adjustments and ROMM pivot")
