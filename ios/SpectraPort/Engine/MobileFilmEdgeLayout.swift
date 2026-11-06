import CoreGraphics
import Foundation

/// Output-only Film Edge beta. This does not claim to replace the Mac's
/// RFC-032 native overscan/emulsion pass. The native film/print and masks
/// are left untouched until engine-side film-edge parity is validated.
enum MobileFilmEdgeFormat: String, CaseIterable, Identifiable, Codable {
    case f135 = "135"
    case half = "135_half"
    case f645 = "120_645"
    case f6x6 = "120_6x6"
    case f6x7 = "120_6x7"
    case f6x8 = "120_6x8"
    case f6x9 = "120_6x9"
    case xpan = "135_xpan"
    case f6x12 = "120_6x12"
    case f6x17 = "120_6x17"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .f135: "135 · 标准"
        case .half: "135 · 半格"
        case .f645: "120 · 645"
        case .f6x6: "120 · 6×6"
        case .f6x7: "120 · 6×7"
        case .f6x8: "120 · 6×8"
        case .f6x9: "120 · 6×9"
        case .xpan: "135 · XPan"
        case .f6x12: "120 · 6×12"
        case .f6x17: "120 · 6×17"
        }
    }
    var gateMM: CGSize {
        switch self {
        case .f135: CGSize(width: 36, height: 24)
        case .half: CGSize(width: 24, height: 18)
        case .f645: CGSize(width: 56, height: 41.5)
        case .f6x6: CGSize(width: 56, height: 56)
        case .f6x7: CGSize(width: 69.5, height: 56)
        case .f6x8: CGSize(width: 76, height: 56)
        case .f6x9: CGSize(width: 84, height: 56)
        case .xpan: CGSize(width: 65, height: 24)
        case .f6x12: CGSize(width: 112, height: 56)
        case .f6x17: CGSize(width: 168, height: 56)
        }
    }
    var perforated: Bool { self == .f135 || self == .half || self == .xpan }
    var filmWidthMM: CGFloat { perforated ? 35 : 61 }
}

enum MobileFilmEdgeView: String, CaseIterable, Identifiable, Codable {
    case strip = "胶片条"
    case filed = "归档"
    var id: String { rawValue }
}
enum MobileFilmEdgeHoles: String, CaseIterable, Identifiable, Codable {
    case white = "透光"
    case black = "黑底"
    var id: String { rawValue }
}

struct MobileFilmEdgeSettings: Equatable, Codable {
    var enabled = false
    var format = MobileFilmEdgeFormat.f135
    var view = MobileFilmEdgeView.strip
    var holes = MobileFilmEdgeHoles.white
    var frameNumber = 1
    var fog = 0.4
    var leaks = 0.0
    var edgeText = ""

    var isIdentity: Bool { !enabled }

    func normalized() -> Self {
        var a = self
        a.frameNumber = min(99, max(0, a.frameNumber))
        a.fog = min(4, max(0, a.fog))
        a.leaks = min(4, max(0, a.leaks))
        a.edgeText = String(a.edgeText.prefix(32))
        return a
    }
}

struct MobileFilmEdgeLayout {
    let canvas: CGSize
    let filmRect: CGRect
    let gateRect: CGRect
    let holes: [CGRect]
    let edgeLabelRect: CGRect
    let isPortrait: Bool

    static func make(
        image: CGSize, settings: MobileFilmEdgeSettings, pixelLimit: Int
    ) -> MobileFilmEdgeLayout? {
        guard image.width > 0, image.height > 0, pixelLimit > 0,
              image.width.isFinite, image.height.isFinite else { return nil }
        let gate = settings.format.gateMM
        let landscape = image.width >= image.height
        let long = max(gate.width, gate.height)
        let short = min(gate.width, gate.height)
        let widthMM = settings.format.filmWidthMM
        let alongMM = long + (settings.view == .strip ? 8 : 9)
        let backing: CGFloat = settings.view == .filed ? 4.0 : 0
        let filmSize = landscape
            ? CGSize(width: alongMM, height: widthMM)
            : CGSize(width: widthMM, height: alongMM)
        let outerMM = CGSize(width: filmSize.width + 2*backing,
                             height: filmSize.height + 2*backing)
        let initialPPM = max(image.width, image.height) / max(1, long)
        let area = Double(outerMM.width * outerMM.height) *
                   Double(initialPPM * initialPPM)
        let shrink = min(1, sqrt(Double(pixelLimit) / max(1, area)))
        let ppm = initialPPM * CGFloat(shrink)
        let output = CGSize(width: max(16, floor(outerMM.width * ppm)),
                            height: max(16, floor(outerMM.height * ppm)))
        let fx = backing * ppm
        let fy = backing * ppm
        let filmRect = CGRect(x: fx, y: fy, width: filmSize.width*ppm,
                              height: filmSize.height*ppm)
        let gateWidth = (landscape ? long : short)*ppm
        let gateHeight = (landscape ? short : long)*ppm
        let gateRect = CGRect(
            x: filmRect.midX - gateWidth/2,
            y: filmRect.midY - gateHeight/2,
            width: gateWidth, height: gateHeight
        )
        let labelRect: CGRect
        if landscape {
            labelRect = CGRect(x: filmRect.minX + 2*ppm,
                               y: gateRect.maxY + 0.9*ppm,
                               width: filmRect.width - 4*ppm,
                               height: max(1, filmRect.maxY-gateRect.maxY-1.4*ppm))
        } else {
            labelRect = CGRect(x: gateRect.maxX + 0.8*ppm,
                               y: filmRect.minY + 2*ppm,
                               width: max(1,filmRect.maxX-gateRect.maxX-1.2*ppm),
                               height: filmRect.height-4*ppm)
        }
        var holes: [CGRect] = []
        if settings.format.perforated {
            let holeAlong = 2.7*ppm
            let holeAcross = 1.8*ppm
            let step = 4.75*ppm
            let distance = (landscape ? filmRect.width : filmRect.height)
            let count = max(1, Int(floor((distance-4*ppm)/step)))
            for index in 0..<count {
                let pos = 2*ppm + (CGFloat(index)+0.5) *
                          (distance - 4*ppm)/CGFloat(count)
                if landscape {
                    let x = filmRect.minX + pos-holeAlong/2
                    holes.append(CGRect(x: x, y: filmRect.minY+1.25*ppm,
                                        width: holeAlong, height: holeAcross))
                    holes.append(CGRect(x: x, y: filmRect.maxY-3.05*ppm,
                                        width: holeAlong, height: holeAcross))
                } else {
                    let y = filmRect.minY + pos-holeAlong/2
                    holes.append(CGRect(x: filmRect.minX+1.25*ppm,y:y,
                                        width: holeAcross,height:holeAlong))
                    holes.append(CGRect(x: filmRect.maxX-3.05*ppm,y:y,
                                        width: holeAcross,height:holeAlong))
                }
            }
        }
        return MobileFilmEdgeLayout(canvas: output, filmRect: filmRect,
                                     gateRect: gateRect, holes: holes,
                                     edgeLabelRect: labelRect,
                                     isPortrait: !landscape)
    }
}
