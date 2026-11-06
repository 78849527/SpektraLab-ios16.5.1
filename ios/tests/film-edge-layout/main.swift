import CoreGraphics
import Foundation

func verify(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { fatalError("Film edge geometry: " + label) }
}
let photo = CGSize(width: 4000, height: 3000)
var settings = MobileFilmEdgeSettings()
settings.enabled = true
for format in MobileFilmEdgeFormat.allCases {
    settings.format = format
    let layout = MobileFilmEdgeLayout.make(
        image: photo, settings: settings, pixelLimit: 6_000_000)!
    verify(layout.canvas.width * layout.canvas.height <= 6_000_000, "budget \(format)")
    verify(layout.filmRect.contains(layout.gateRect), "gate inside film \(format)")
    verify(layout.canvas.width > 0 && layout.canvas.height > 0, "dimensions \(format)")
    if format.perforated {
        verify(layout.holes.count >= 8, "135 perforation row \(format)")
    } else {
        verify(layout.holes.isEmpty, "120 has no sprockets \(format)")
    }
}
settings.format = .f135
let a = MobileFilmEdgeLayout.make(image: photo, settings: settings,
                                  pixelLimit: 6_000_000)!
verify(a.gateRect.width > a.gateRect.height, "landscape gate")
verify(a.canvas.width < 4000 && a.canvas.height < 3000, "bounded photo")
let portrait = MobileFilmEdgeLayout.make(
    image: CGSize(width: 3000, height: 4000),
    settings: settings, pixelLimit: 6_000_000)!
verify(portrait.gateRect.height > portrait.gateRect.width, "portrait gate")
verify(portrait.canvas.width * portrait.canvas.height <= 6_000_000,
       "portrait bounded")
settings.view = .filed
let filed = MobileFilmEdgeLayout.make(image: photo, settings: settings,
                                      pixelLimit: 6_000_000)!
verify(filed.filmRect.minX > 0 && filed.filmRect.minY > 0, "filed backing")
settings.frameNumber = 150
settings.fog = -4
settings.leaks = 9
verify(settings.normalized().frameNumber == 99, "frame bounds")
verify(settings.normalized().fog == 0, "fog bounds")
verify(settings.normalized().leaks == 4, "leak bounds")
print("FILM_EDGE_LAYOUT_BUILD34_PASS")
