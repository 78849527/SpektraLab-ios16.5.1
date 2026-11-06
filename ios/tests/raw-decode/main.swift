// These test-only C ABI stubs keep the Core Image/options fixture independent
// from the device-only LibRaw engine archive. The app target uses Bridge.h.
func spk_raw_probe_file(_ path: UnsafePointer<CChar>?,
                        _ width: UnsafeMutablePointer<UInt32>?,
                        _ height: UnsafeMutablePointer<UInt32>?,
                        _ error: UnsafeMutablePointer<CChar>?,
                        _ errorCapacity: Int) -> Int32 { 0 }
func spk_raw_decode_file(_ path: UnsafePointer<CChar>?, _ preview: Int32,
                         _ rgb: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                         _ width: UnsafeMutablePointer<UInt32>?,
                         _ height: UnsafeMutablePointer<UInt32>?,
                         _ nativeWidth: UnsafeMutablePointer<UInt32>?,
                         _ nativeHeight: UnsafeMutablePointer<UInt32>?,
                         _ error: UnsafeMutablePointer<CChar>?,
                         _ errorCapacity: Int) -> Int32 { 0 }
func spk_raw_free_buffer(_ buffer: UnsafeMutableRawPointer?) {}

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
