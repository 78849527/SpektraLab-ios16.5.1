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

// Original macOS analytical local-mask packing.
let linear = EditMask.make(.linearGradient)
expect(linear.components.count == 1, "linear mask component")
expect(linear.uniform().components.0.kind == 0, "desktop linear kind index")
let radial = EditMask.make(.radialGradient)
expect(radial.uniform().components.0.kind == 1, "desktop radial kind index")
let luminance = EditMask.make(.luminanceRange)
expect(luminance.uniform().components.0.kind == 2, "desktop luminance kind index")
let color = EditMask.make(.colorRange)
expect(color.uniform().components.0.kind == 3, "desktop colour kind index")
let brush = EditMask.make(.brush)
expect(brush.needsRaster && brush.uniform().components.0.kind == 4,
       "brush requires unavailable raster and must never silently render")
var mask = radial
mask.adjustments.exposure = 1.0
mask.amount = 0.6
let packed = mask.uniform()
expect(close(Double(packed.adjustments.exposureGain), 2), "local one stop = global one stop")
expect(close(Double(packed.amount), 0.6), "local mask opacity")
expect(packed.componentCount == 1 && packed.rasterSlice == MaskUniform.noRaster,
       "radial mask analytical and needs no bitmap")
expect(MemoryLayout<MaskUniform>.stride >
       MemoryLayout<Layer2Uniforms>.stride, "mask uniform layout is nonzero")
let maskJSON = try JSONEncoder().encode(mask)
let maskBack = try JSONDecoder().decode(EditMask.self, from: maskJSON)
expect(maskBack == mask, "lossless mask serialization")

// The migrated iOS film settings preserve original desktop grade and masks,
// while distinguishing physical print changes from post-print Layer2 changes.
enum PortError: Error { case message(String) }
let stock = FilmSettings(
    filmStock: "kodak_portra_400", printStock: "kodak_portra_endura",
    exposureEV: 0, grainAmount: 1, halationAmount: 1, printExposure: 1,
    magentaShift: 0, yellowShift: 0
)
var layerGrade = Adjustments()
layerGrade.exposure = 1
let graded = FilmSettings(
    filmStock: stock.filmStock, printStock: stock.printStock,
    exposureEV: 0, grainAmount: 1, halationAmount: 1, printExposure: 1,
    magentaShift: 0, yellowShift: 0, adjustments: layerGrade, masks: [mask]
)
expect(stock.samePhysicalPrint(as: graded), "Layer2 must reuse the spectral print")
expect(stock != graded, "snapshot tracks grade/mask edits")
let newSettingData = try JSONEncoder().encode(graded)
let decodedGraded = try JSONDecoder().decode(FilmSettings.self, from: newSettingData)
expect(decodedGraded == graded, "new preset roundtrip")
let oldData = try JSONEncoder().encode(stock)
var oldJSON = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
oldJSON.removeValue(forKey: "adjustments")
oldJSON.removeValue(forKey: "masks")
let oldPreset = try JSONDecoder().decode(
    FilmSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
expect(oldPreset.adjustments.isNeutral && oldPreset.masks.isEmpty,
       "previous release's looks default to neutral grading and no masks")
let changedPhysical = FilmSettings(
    filmStock: stock.filmStock, printStock: stock.printStock,
    exposureEV: 0.5, grainAmount: 1, halationAmount: 1,
    printExposure: 1, magentaShift: 0, yellowShift: 0
)
expect(!stock.samePhysicalPrint(as: changedPhysical),
       "negative/exposure changes must invalidate spectral cache")
print("Verified: Mac curves, grading, mask packing, old presets and spectral cache isolation")
