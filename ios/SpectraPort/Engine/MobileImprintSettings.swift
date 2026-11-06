import CoreGraphics
import Foundation

/// Mac RFC-031 date back choices (lcd, dots, data), independent of the
/// film-edge strip. A bare photograph can also carry LCD/dot date imprint.
enum MobileDateBackFace: String, CaseIterable, Identifiable, Codable {
    case lcd = "LCD"
    case dots = "点阵"
    case data = "拍摄数据"
    var id: String { rawValue }
}
enum MobileDateBackOrder: String, CaseIterable, Identifiable, Codable {
    case japan = "年 月 日"
    case us = "月 日 年"
    var id: String { rawValue }
}
enum MobileImprintPlacement: String, CaseIterable, Identifiable, Codable {
    case frame = "画面内"
    case rebate = "片边"
    var id: String { rawValue }
}
enum MobileImprintCorner: String, CaseIterable, Identifiable, Codable {
    case br = "右下"
    case bl = "左下"
    case tr = "右上"
    case tl = "左上"
    var id: String { rawValue }
    var right: Bool { self == .br || self == .tr }
    var bottom: Bool { self == .br || self == .bl }
}
struct MobileDateBackSettings: Equatable, Codable {
    var enabled = false
    var face: MobileDateBackFace = .lcd
    var order: MobileDateBackOrder = .japan
    var placement: MobileImprintPlacement = .frame
    var corner: MobileImprintCorner = .br
    var date: Date = Date()
    var fromEXIF = false
    /// User override. Empty uses the date picked above.
    var customText = ""
    var dataText = ""
    var withData = false
    var size = 1.0
    var brightnessEV = 3.5
    var insetXMM = 3.0
    var insetYMM = 2.4

    var printedText: String {
        if face == .data { return dataText.isEmpty ? customText : dataText }
        if !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customText
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Self.format(year: c.year ?? 2026, month: c.month ?? 1,
                           day: c.day ?? 1, order: order)
    }

    static func format(year: Int, month: Int, day: Int,
                       order: MobileDateBackOrder) -> String {
        let yearPart = String(format: "'%02d", ((year % 100) + 100) % 100)
        switch order {
        case .japan: return "\(yearPart) \(month) \(day)"
        case .us: return "\(month) \(day) \(yearPart)"
        }
    }
    func normalized() -> Self {
        var s = self
        s.size = min(3, max(0.4, s.size))
        s.brightnessEV = min(8, max(-2, s.brightnessEV))
        s.insetXMM = min(30, max(0, s.insetXMM))
        s.insetYMM = min(30, max(0, s.insetYMM))
        s.customText = String(s.customText.prefix(48))
        s.dataText = String(s.dataText.prefix(64))
        return s
    }
}

enum MobileSignatureStyle: String, CaseIterable, Identifiable, Codable {
    case type = "艺术字体"
    case drawn = "手写轨迹"
    var id: String { rawValue }
}
enum MobileSignatureColor: String, CaseIterable, Identifiable, Codable {
    case cream = "暖白"
    case white = "纯白"
    case amber = "琥珀"
    case dark = "深灰"
    var id: String { rawValue }
}
struct MobileSignatureSettings: Equatable, Codable {
    var enabled = false
    var style: MobileSignatureStyle = .type
    var text = ""
    /// Stored in normalized [0,1] coordinates, for resolution independence.
    var strokes: [[CGPoint]] = []
    var color: MobileSignatureColor = .cream
    var corner: MobileImprintCorner = .br
    var scale = 1.0
    var opacity = 0.80
    var offsetX = 0.035
    var offsetY = 0.045

    var hasInk: Bool {
        switch style {
        case .type: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .drawn: return strokes.contains { $0.count > 1 }
        }
    }
    func normalized() -> Self {
        var s = self
        s.scale = min(3, max(0.35, s.scale))
        s.opacity = min(1, max(0.05, s.opacity))
        s.offsetX = min(0.25, max(0, s.offsetX))
        s.offsetY = min(0.25, max(0, s.offsetY))
        s.text = String(s.text.prefix(80))
        s.strokes = Array(s.strokes.prefix(80)).map {
            Array($0.prefix(1000)).map { point in
                CGPoint(x: max(0, min(1, point.x)), y: max(0, min(1, point.y)))
            }
        }
        return s
    }
}
