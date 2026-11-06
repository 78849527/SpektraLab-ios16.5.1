import CoreImage
import Foundation
import UniformTypeIdentifiers

func verify(_ test: @autoclosure () -> Bool, _ title: String) {
    if !test() { fatalError("RAW regression: " + title) }
}
verify(RawImageDeveloper.isRaw(filename: "XT5.RAF"), "Fujifilm RAF")
verify(RawImageDeveloper.isRaw(filename: "phone.dng"), "DNG")
verify(RawImageDeveloper.isRaw(filename: "Canon.CR3"), "Canon")
verify(RawImageDeveloper.isRaw(filename: "SONY.ARW"), "Sony")
verify(!RawImageDeveloper.isRaw(filename: "picture.jpeg"), "JPEG should stay flat")
verify(!RawImageDeveloper.isRaw(filename: "picture.png"), "PNG should stay flat")
verify(RawImageDeveloper.isRaw(filename: "photo",
    typeID: UTType.rawImage.identifier), "RAW content type")
let asShot = RAWDecodeOptions(identifierHint: nil)
verify(asShot.useAsShot, "default camera WB")
var custom = asShot
custom.useAsShot = false
custom.temperature = 6000
custom.tint = -20
verify(custom != asShot, "WB cache invalidation")
custom.temperature = 70000
custom.tint = -600
verify(custom.safeTemperature == 50000, "temperature clamp")
verify(custom.safeTint == -150, "tint clamp")
do {
    _ = try RawImageDeveloper.probe(Data([0, 1, 2]), hint: nil)
    fatalError("Invalid RAW data should be rejected")
} catch is RAWDevelopmentError {
    // No embedded JPEG fallback.
}
print("RAW_DECODE_BUILD33_PASS")
