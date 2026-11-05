import SwiftUI

/// iPhone touch UI for the unmodified Mac CurveSet/Curve maths:
/// five 256-sample LUT channels, Fritsch-Carlson interpolation, endpoint
/// anchoring and neighbour ordering. The backing model is not a new curve
/// approximation; only the gesture UI differs from macOS mouse controls.
struct MobileCurveEditor: View {
    @Binding var curves: CurveSet
    @State private var channel: CurveChannel = .rgb
    @State private var draggingIndex: Int?

    private func unit(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(1, point.x / max(1, size.width))),
            y: max(0, min(1, 1 - point.y / max(1, size.height)))
        )
    }

    private func edit(_ mutate: (inout Curve) -> Void) {
        var copy = curves
        var c = copy[channel]
        mutate(&c)
        copy[channel] = c
        curves = copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("RGB / 亮度曲线")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Button("复位当前通道") {
                    edit { $0 = .identity }
                }
                .font(.system(size: 11))
                .foregroundStyle(DarkroomStyle.accent)
            }

            HStack(spacing: 4) {
                ForEach(CurveChannel.allCases) { item in
                    Button {
                        channel = item
                        draggingIndex = nil
                    } label: {
                        Text(item == .luma ? "亮度" : item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(channel == item
                                ? DarkroomStyle.background : DarkroomStyle.primary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(channel == item
                                ? DarkroomStyle.accent : DarkroomStyle.raised,
                                in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            GeometryReader { geo in
                let side = min(geo.size.width, 290.0)
                let square = CGSize(width: side, height: side)
                Canvas { context, size in
                    let w = size.width, h = size.height
                    var grid = Path()
                    for fraction in [0.25, 0.5, 0.75] {
                        let u = CGFloat(fraction)
                        grid.move(to: CGPoint(x: w * u, y: 0))
                        grid.addLine(to: CGPoint(x: w * u, y: h))
                        grid.move(to: CGPoint(x: 0, y: h * u))
                        grid.addLine(to: CGPoint(x: w, y: h * u))
                    }
                    context.stroke(grid, with: .color(.gray.opacity(0.35)),
                                   lineWidth: 0.6)
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: h))
                    diagonal.addLine(to: CGPoint(x: w, y: 0))
                    context.stroke(diagonal, with: .color(.white.opacity(0.32)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    let curve = curves[channel]
                    var line = Path()
                    for i in 0...255 {
                        let x = CGFloat(i) / 255
                        let y = curve.evaluate(x)
                        let point = CGPoint(x: x * w, y: (1 - y) * h)
                        if i == 0 { line.move(to: point) }
                        else { line.addLine(to: point) }
                    }
                    let tint: Color = {
                        switch channel {
                        case .rgb: return DarkroomStyle.accent
                        case .luma: return .white
                        case .red: return .red
                        case .green: return .green
                        case .blue: return .blue
                        }
                    }()
                    context.stroke(line, with: .color(tint), lineWidth: 2.5)
                    for (index, p) in curve.points.enumerated() {
                        let radius: CGFloat = draggingIndex == index ? 6 : 5
                        let origin = CGPoint(x: p.x * w - radius,
                                             y: (1 - p.y) * h - radius)
                        let circle = Path(ellipseIn: CGRect(
                            origin: origin, size: CGSize(
                                width: radius * 2, height: radius * 2)))
                        context.fill(circle, with: .color(DarkroomStyle.surface))
                        context.stroke(circle, with: .color(tint), lineWidth: 2)
                    }
                }
                .frame(width: square.width, height: square.height)
                .background(DarkroomStyle.background,
                            in: RoundedRectangle(cornerRadius: 8))
                .border(DarkroomStyle.line, width: 1)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { event in
                            let p = unit(event.location, size: square)
                            if draggingIndex == nil {
                                let c = curves[channel]
                                if let index = c.index(near: p, in: square) {
                                    draggingIndex = index
                                } else {
                                    var addedIndex = 0
                                    edit { addedIndex = $0.insert(p) }
                                    draggingIndex = addedIndex
                                }
                            }
                            guard let index = draggingIndex else { return }
                            edit { $0.move(index, to: p) }
                        }
                        .onEnded { _ in draggingIndex = nil }
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: min(290, UIScreen.main.bounds.width - 55))

            Text("点按添加控制点，拖动修改曲线；端点不能删除。使用「复位当前通道」恢复直线。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)
        }
    }
}
