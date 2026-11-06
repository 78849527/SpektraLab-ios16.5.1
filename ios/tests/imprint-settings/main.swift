import CoreGraphics
import Foundation

func assertOK(_ v: @autoclosure () -> Bool, _ why: String) {
    if !v() { fatalError("Imprint: " + why) }
}
assertOK(MobileDateBackSettings.format(year: 2026, month: 11, day: 6,
    order: .japan) == "'26 11 6", "Japan order")
assertOK(MobileDateBackSettings.format(year: 2026, month: 11, day: 6,
    order: .us) == "11 6 '26", "US order")
var date = MobileDateBackSettings()
date.customText = "A VERY LONG STRING WHICH WILL BE CLIPPED AT 48 CHARS ABCDEFGHIJKLMNOP"
date.size = 9
date.insetXMM = -3
assertOK(date.normalized().size == 3 && date.normalized().insetXMM == 0,
         "Date limits")
assertOK(date.normalized().customText.count == 48, "date string length")
var sign = MobileSignatureSettings()
sign.style = .drawn
sign.strokes = [[CGPoint(x: 0, y: 0), CGPoint(x: 1.5, y: -1)]]
assertOK(sign.hasInk, "hand drawn mode detects ink")
assertOK(sign.normalized().strokes[0][1] == CGPoint(x: 1, y: 0), "ink bounds")
sign.style = .type
sign.text = "Sample signature"
assertOK(sign.hasInk, "typed signature detects ink")
let json = try JSONEncoder().encode(sign)
let decoded = try JSONDecoder().decode(MobileSignatureSettings.self, from: json)
assertOK(decoded == sign, "signature settings persisted")
print("IMPRINT_MODEL_BUILD36_PASS")
