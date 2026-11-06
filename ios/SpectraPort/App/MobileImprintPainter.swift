import CoreGraphics
import Foundation
import UIKit

/// Film-carrier gate shape families from Mac RFC-032. Rendering stays in
/// the mobile output compositor; native emulsion overscan is a separate
/// whole-frame GPU pipeline and must not be described as pixel parity.
enum MobileFilmGatePath {
    static func make(_ r: CGRect, gate: MobileFilmGate) -> UIBezierPath {
        let kind = gate == .auto ? MobileFilmGate.rounded : gate
        switch kind {
        case .auto, .rounded:
            return UIBezierPath(roundedRect: r,
                cornerRadius: max(0.8, min(r.width,r.height)*0.007))
        case .square:
            return UIBezierPath(rect: r)
        case .eared, .shouldered, .kicked, .burnished:
            let inset = min(r.width,r.height) *
                (kind == .eared ? 0.012 : kind == .shouldered ? 0.017 : 0.023)
            let p = UIBezierPath()
            let left = r.minX, right = r.maxX, top = r.minY, bottom = r.maxY
            p.move(to: CGPoint(x: left + inset, y: top))
            p.addLine(to: CGPoint(x: right - inset, y: top))
            if kind == .eared {
                p.addLine(to: CGPoint(x: right + inset*0.35, y: top - inset*0.35))
                p.addLine(to: CGPoint(x: right, y: top + inset))
            } else {
                p.addLine(to: CGPoint(x: right - inset*0.20, y: top + inset*0.55))
                p.addLine(to: CGPoint(x: right, y: top + inset))
            }
            p.addLine(to: CGPoint(x: right, y: bottom - inset))
            if kind == .kicked || kind == .burnished {
                p.addLine(to: CGPoint(x: right - inset*0.6, y: bottom - inset*0.25))
                p.addLine(to: CGPoint(x: right - inset*1.2, y: bottom + inset*0.25))
                p.addLine(to: CGPoint(x: right - inset*2, y: bottom))
            } else {
                p.addLine(to: CGPoint(x: right - inset, y: bottom))
            }
            p.addLine(to: CGPoint(x: left + inset, y: bottom))
            if kind == .eared {
                p.addLine(to: CGPoint(x: left - inset*0.22, y: bottom + inset*0.33))
            } else {
                p.addLine(to: CGPoint(x: left + inset*0.15, y: bottom - inset*0.5))
            }
            p.addLine(to: CGPoint(x: left, y: bottom - inset))
            p.addLine(to: CGPoint(x: left, y: top + inset))
            p.close()
            return p
        }
    }

    /// Small deterministic abrasion marks along the cut film window; no
    /// random flicker when adjusting other controls or exporting at 6MP.
    static func drawBurnished(in context: CGContext, layout: MobileFilmEdgeLayout,
                             frameNumber: Int) {
        let r = layout.gateRect
        let edge = min(r.width,r.height)
        context.saveGState()
        context.setLineWidth(max(0.55, edge * 0.0007))
        context.setStrokeColor(UIColor(
            red: 0.95, green: 0.58, blue: 0.27, alpha: 0.30).cgColor)
        for n in 0..<74 {
            let t = CGFloat(n + 2) / 78
            let random = CGFloat((n * 149 + frameNumber * 313) % 59) / 59
            let x = r.minX + r.width * t
            let vertical = n.isMultiple(of: 2)
            if vertical {
                let y = n.isMultiple(of: 3) ? r.minY : r.maxY
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(
                    x: x + (random - 0.5) * edge * 0.004,
                    y: y + (n.isMultiple(of: 3) ? 1 : -1) *
                            edge * (0.003 + random * 0.005)))
            } else {
                let y = r.minY + r.height * t
                let side = n.isMultiple(of: 3) ? r.minX : r.maxX
                context.move(to: CGPoint(x: side, y: y))
                context.addLine(to: CGPoint(
                    x: side + (n.isMultiple(of: 3) ? 1 : -1) *
                       edge * (0.003 + random * 0.005),
                    y: y + (random - 0.5) * edge * 0.003))
            }
        }
        context.strokePath()
        context.restoreGState()
    }
}

enum MobileImprintPainter {
    private static func target(
        _ corner: MobileImprintCorner, inside rect: CGRect,
        size: CGSize, insetX: CGFloat, insetY: CGFloat
    ) -> CGRect {
        let x = corner.right
            ? rect.maxX - insetX - size.width
            : rect.minX + insetX
        let y = corner.bottom
            ? rect.maxY - insetY - size.height
            : rect.minY + insetY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func drawDate(
        context: CGContext, layout: MobileFilmEdgeLayout,
        settings: MobileFilmEdgeSettings
    ) {
        let date = settings.dateBack.normalized()
        guard date.enabled else { return }
        // No historical camera date-back on panoramic XPan / 6x12 / 6x17.
        if settings.enabled {
            switch settings.format {
            case .xpan, .f6x12, .f6x17: return
            default: break
            }
        }
        let isMedium = settings.enabled && !settings.format.perforated
        let inMargin = settings.enabled && (isMedium || date.placement == .rebate)
        let gate = layout.gateRect
        let rect: CGRect
        if inMargin {
            if layout.isPortrait {
                rect = CGRect(x: layout.filmRect.minX, y: gate.minY,
                              width: max(1, gate.minX-layout.filmRect.minX),
                              height: gate.height)
            } else {
                rect = CGRect(x: gate.minX, y: layout.filmRect.minY,
                              width: gate.width,
                              height: max(1, gate.minY-layout.filmRect.minY))
            }
        } else {
            rect = gate
        }

        let text = date.printedText
        guard !text.isEmpty else { return }
        let pixelMM = min(gate.width,gate.height) /
            (settings.enabled ? (settings.format.perforated ? 24 : 56) : 35)
        let fontSize = max(7, min(gate.height * 0.067,
                           pixelMM * 1.13 * CGFloat(date.size)))
        let color = UIColor(red: 1, green: 0.39, blue: 0.16,
                            alpha: min(0.98,max(0.22, CGFloat(pow(2,
                                  (date.brightnessEV-3.5)/5)) * 0.80)))
        if inMargin {
            let compressed = max(7, min(fontSize, rect.width * 0.68))
            let area = layout.isPortrait
                ? CGRect(x: rect.minX, y: rect.minY + 3*pixelMM,
                         width: rect.width, height: rect.height - 6*pixelMM)
                : CGRect(x: rect.minX + 3*pixelMM, y: rect.minY,
                         width: rect.width - 6*pixelMM, height: rect.height)
            drawImprintText(
                text, face: date.face, context: context,
                rect: area, fontSize: compressed, color: color,
                rotated: layout.isPortrait
            )
        } else {
            let width = min(rect.width * 0.72,
                            CGFloat(text.count) * fontSize * 0.62 + fontSize)
            let size = CGSize(width: width, height: fontSize*1.28)
            let origin = target(date.corner, inside: rect, size: size,
                                insetX: CGFloat(date.insetXMM) * pixelMM,
                                insetY: CGFloat(date.insetYMM) * pixelMM)
            drawImprintText(text, face: date.face, context: context,
                            rect: origin, fontSize: fontSize, color: color,
                            rotated: false)
        }
        if date.withData && date.face != .data &&
           !date.dataText.isEmpty && settings.enabled {
            let label = date.dataText as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(
                    ofSize: max(7, fontSize*0.46), weight: .medium),
                .foregroundColor: color.withAlphaComponent(0.60)
            ]
            let origin = CGRect(x: layout.filmRect.minX+3*pixelMM,
                                y: layout.filmRect.maxY - max(9, fontSize*0.70),
                                width: layout.filmRect.width-6*pixelMM,
                                height: max(9, fontSize*0.65))
            label.draw(in: origin, withAttributes: attrs)
        }
    }

    private static func drawImprintText(
        _ text: String, face: MobileDateBackFace,
        context: CGContext, rect: CGRect,
        fontSize: CGFloat, color: UIColor, rotated: Bool
    ) {
        guard rect.width > 1, rect.height > 1 else { return }
        context.saveGState()
        let target: CGRect
        if rotated {
            context.translateBy(x: rect.maxX, y: rect.minY)
            context.rotate(by: .pi/2)
            target = CGRect(x: 0, y: 0,
                            width: rect.height, height: rect.width)
        } else {
            target = rect
        }
        if face == .dots {
            drawDots(text, in: target, size: fontSize, color: color)
        } else {
            let font = UIFont.monospacedDigitSystemFont(
                ofSize: fontSize, weight: face == .lcd ? .medium : .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .kern: face == .lcd ? 1.8 : 0.3
            ]
            (text as NSString).draw(in: target, withAttributes: attrs)
        }
        context.restoreGState()
    }

    /// Reproducible 5x7 LED dots; date characters mirror Mac RFC-031's
    /// dots face rather than falling back to a generic printed font.
    private static let dotGlyphs: [Character: [String]] = [
        "0": ["01110","10001","10011","10101","11001","10001","01110"],
        "1": ["00100","01100","00100","00100","00100","00100","01110"],
        "2": ["01110","10001","00001","00010","00100","01000","11111"],
        "3": ["11110","00001","00001","01110","00001","00001","11110"],
        "4": ["00010","00110","01010","10010","11111","00010","00010"],
        "5": ["11111","10000","11110","00001","00001","10001","01110"],
        "6": ["00110","01000","10000","11110","10001","10001","01110"],
        "7": ["11111","00001","00010","00100","01000","01000","01000"],
        "8": ["01110","10001","10001","01110","10001","10001","01110"],
        "9": ["01110","10001","10001","01111","00001","00010","11100"],
        "'": ["00100","00100","01000","00000","00000","00000","00000"],
        "-": ["00000","00000","00000","11111","00000","00000","00000"],
        ".": ["00000","00000","00000","00000","00000","00110","00110"],
        "/": ["00001","00001","00010","00100","01000","10000","10000"],
        ":": ["00000","00100","00100","00000","00100","00100","00000"],
        " ": ["00000","00000","00000","00000","00000","00000","00000"]
    ]

    private static func drawDots(_ value: String, in rect: CGRect,
                                 size: CGFloat, color: UIColor) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let glyphs = Array(value.prefix(48))
        let dot = max(0.75, min(size/10, rect.width /
                       (CGFloat(max(1,glyphs.count))*7)))
        let pitch = dot*1.4
        context.saveGState()
        context.setFillColor(color.cgColor)
        for (index, character) in glyphs.enumerated() {
            let rows = dotGlyphs[character] ?? dotGlyphs[" "]!
            for (y,row) in rows.enumerated() {
                for (x,bit) in row.enumerated() where bit == "1" {
                    context.fillEllipse(in: CGRect(
                        x: rect.minX + CGFloat(index)*6*pitch + CGFloat(x)*pitch,
                        y: rect.minY + CGFloat(y)*pitch,
                        width: dot, height: dot))
                }
            }
        }
        context.restoreGState()
    }

    static func drawSignature(
        context: CGContext, layout: MobileFilmEdgeLayout,
        settings: MobileFilmEdgeSettings
    ) {
        let signature = settings.signature.normalized()
        guard signature.enabled && signature.hasInk else { return }
        let gate = layout.gateRect
        let width = gate.width * min(0.55, 0.27*CGFloat(signature.scale))
        let height = gate.height * min(0.27, 0.11*CGFloat(signature.scale))
        let box = target(signature.corner, inside: gate,
                         size: CGSize(width: width, height: height),
                         insetX: gate.width*CGFloat(signature.offsetX),
                         insetY: gate.height*CGFloat(signature.offsetY))
        let ink: UIColor
        switch signature.color {
        case .cream: ink = UIColor(red: 0.99,green: 0.93,blue: 0.78,alpha: 1)
        case .white: ink = .white
        case .amber: ink = UIColor(red: 0.97,green: 0.66,blue: 0.31,alpha: 1)
        case .dark: ink = UIColor(white: 0.12,alpha: 1)
        }
        context.saveGState()
        context.setAlpha(CGFloat(signature.opacity))
        if signature.style == .type {
            let font = UIFont(name: "SnellRoundhand", size: max(10, box.height*0.82))
                ?? UIFont.italicSystemFont(ofSize: max(10, box.height*0.8))
            (signature.text as NSString).draw(in: box, withAttributes: [
                .font: font, .foregroundColor: ink
            ])
        } else {
            context.setStrokeColor(ink.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(max(1, min(gate.width,gate.height)*0.0032 *
                                     CGFloat(signature.scale)))
            for stroke in signature.strokes where stroke.count > 1 {
                for (i,point) in stroke.enumerated() {
                    let position = CGPoint(x: box.minX+point.x*box.width,
                                           y: box.minY+point.y*box.height)
                    if i == 0 { context.move(to: position) }
                    else { context.addLine(to: position) }
                }
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}
