import SwiftUI

/// Finger-driven masks displayed in the *same* photoRect as LocalMaskCanvas.
/// The photo and handles share a single fitted geometry source, with no
/// UIScrollView, zoom restoration or independent photo aspect-fit calculation.
/// Only UI positions change; desktop EditMask, shaders and export are untouched.
struct InlineMaskOverlay: View {
    @Binding var masks: [EditMask]
    @Binding var selectedID: UUID?
    let photoRect: CGRect
    let image: UIImage
    let projection: MaskDisplayProjection

    @State private var lineDragStartA: CGPoint?
    @State private var lineDragStartB: CGPoint?
    @State private var draggingSamplePoint: CGPoint?
    @State private var lastSamplePoint: CGPoint?
    @State private var lastSampleMaskID: UUID?
    @State private var lastSampleLuma: Double?

    private var index: Int? {
        if let selectedID,
           let selected = masks.firstIndex(where: { $0.id == selectedID }) {
            return selected
        }
        return masks.isEmpty ? nil : 0
    }

    private func setLinear(_ part: Int, _ touch: CGPoint, rect: CGRect) {
        guard let i = index, masks.indices.contains(i),
              !masks[i].components.isEmpty,
              masks[i].components[0].kind == .linearGradient else { return }
        let value = projection.toSource(touch)
        if part == 0 { masks[i].components[0].a = value }
        else { masks[i].components[0].b = value }
    }

    private func moveLine(_ translation: CGSize, rect: CGRect) {
        guard let i = index, masks.indices.contains(i),
              !masks[i].components.isEmpty,
              masks[i].components[0].kind == .linearGradient else { return }
        if lineDragStartA == nil {
            lineDragStartA = masks[i].components[0].a
            lineDragStartB = masks[i].components[0].b
        }
        guard let a = lineDragStartA, let b = lineDragStartB,
              rect.width > 0, rect.height > 0 else { return }
        // Convert movement in the cropped photo back to native mask UV.
        let delta = projection.sourceDelta(for: translation)
        let dx = max(-min(a.x, b.x),
                     min(1 - max(a.x, b.x), delta.width))
        let dy = max(-min(a.y, b.y),
                     min(1 - max(a.y, b.y), delta.height))
        masks[i].components[0].a = CGPoint(x: a.x + dx, y: a.y + dy)
        masks[i].components[0].b = CGPoint(x: b.x + dx, y: b.y + dy)
    }

    private func editRadial(_ touch: CGPoint, rect: CGRect, axis: Int) {
        guard let i = index, masks.indices.contains(i),
              !masks[i].components.isEmpty,
              masks[i].components[0].kind == .radialGradient else { return }
        if axis == 0 {
            masks[i].components[0].a =
                projection.toSource(touch)
        } else {
            let shape = masks[i].components[0]
            let value = projection.radialRadius(
                for: touch, shape: shape, horizontal: axis == 1
            )
            if axis == 1 { masks[i].components[0].radii.width = value }
            else { masks[i].components[0].radii.height = value }
        }
    }


    private func chooseLuminance(_ touch: CGPoint) {
        guard let i = index, masks.indices.contains(i),
              let component = masks[i].components.first,
              component.kind == .luminanceRange,
              photoRect.contains(touch),
              let cg = image.cgImage else { return }
        let uv = projection.toSource(touch)
        guard let luma = MaskLuminanceSampling.sample(cg, at: uv) else { return }
        let selected = MaskLuminanceSampling.range(around: luma)
        masks[i].components[0].low = selected.low
        masks[i].components[0].high = selected.high
        masks[i].components[0].softness = 0.06
        lastSamplePoint = uv
        lastSampleMaskID = masks[i].id
        lastSampleLuma = luma
    }

    private func luminanceCrosshair(_ uv: CGPoint, brightness: Double?) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(.black.opacity(0.65)).frame(width: 42, height: 42)
                Circle().stroke(DarkroomStyle.accent, lineWidth: 2)
                    .frame(width: 30, height: 30)
                Rectangle().fill(DarkroomStyle.accent).frame(width: 42, height: 2)
                Rectangle().fill(DarkroomStyle.accent).frame(width: 2, height: 42)
                Circle().fill(DarkroomStyle.accent).frame(width: 5, height: 5)
            }
            if let brightness {
                Text("亮度 \(Int((brightness * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.75), in: Capsule())
            }
        }
        .position(projection.toCanvas(uv))
        .allowsHitTesting(false)
    }

    private func handle(_ label: String, at point: CGPoint,
                        tint: Color, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(Color.black.opacity(0.8))
            .frame(width: 28, height: 28)
            .overlay {
                Circle().stroke(tint, lineWidth: 2.5)
            }
            .overlay {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            // Keep hit testing on the 28-pt circle only. Applying .gesture
            // *after* .position would give the gesture the entire photo's
            // proposed layout size, stealing drags from the other handles.
            .contentShape(Circle())
            .accessibilityLabel(label)
            .gesture(
                DragGesture(minimumDistance: 0,
                            coordinateSpace: .named("mask-photo-overlay"))
                    .onChanged { event in onDrag(event.location) }
            )
            .position(point)
            .opacity(photoRect.insetBy(dx: 14, dy: 14).contains(point) ? 1 : 0)
            .allowsHitTesting(photoRect.insetBy(dx: 14, dy: 14).contains(point))
    }

    private func draw(_ shape: MaskComponent, in rect: CGRect,
                      into context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(rect))
        let gold = DarkroomStyle.accent
        if shape.kind == .linearGradient {
            let a = projection.toCanvas(shape.a)
            let b = projection.toCanvas(shape.b)
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            clipped.stroke(line, with: .color(.black.opacity(0.85)), lineWidth: 5)
            clipped.stroke(line, with: .color(gold), lineWidth: 2)
        } else if shape.kind == .radialGradient {
            var boundary = Path()
            for step in 0...96 {
                let theta = CGFloat(step) * .pi * 2 / 96
                let p = projection.toCanvas(
                    projection.radialSourceBoundary(shape, angle: theta))
                if step == 0 { boundary.move(to: p) }
                else { boundary.addLine(to: p) }
            }
            clipped.stroke(boundary, with: .color(.black.opacity(0.85)), lineWidth: 5)
            clipped.stroke(boundary, with: .color(gold), lineWidth: 2)
        }
    }

    var body: some View {
        GeometryReader { geo in
            if let i = index, masks.indices.contains(i),
               let shape = masks[i].components.first, !photoRect.isEmpty {
                ZStack {
                    Canvas { context, _ in
                        draw(shape, in: photoRect, into: context)
                    }
                    .allowsHitTesting(false)

                    if shape.kind == .linearGradient {
                        let a = projection.toCanvas(shape.a)
                        let b = projection.toCanvas(shape.b)
                        let midpoint = CGPoint(x: (a.x + b.x) / 2,
                                               y: (a.y + b.y) / 2)
                        let separation = hypot(b.x - a.x, b.y - a.y)
                        // Grab anywhere along the yellow line to translate
                        // the entire gradient; endpoint handles resize it.
                        Capsule()
                            .fill(Color.white.opacity(0.002))
                            .frame(width: max(40, separation), height: 28)
                            .contentShape(Rectangle())
                            .rotationEffect(Angle(radians:
                                Double(atan2(b.y - a.y, b.x - a.x))))
                            .accessibilityLabel("拖动线性渐变位置")
                            .gesture(
                                // The capsule rotates with the gradient.
                                // Resolve translation in photo-view axes,
                                // otherwise a vertical line may drag sideways.
                                DragGesture(
                                    minimumDistance: 0,
                                    coordinateSpace: .named("mask-photo-overlay")
                                )
                                    .onChanged { value in
                                        moveLine(value.translation, rect: photoRect)
                                    }
                                    .onEnded { _ in
                                        lineDragStartA = nil
                                        lineDragStartB = nil
                                    }
                            )
                            .position(midpoint)

                        handle("线性渐变起点", at: a,
                               tint: DarkroomStyle.accent) { point in
                            setLinear(0, point, rect: photoRect)
                        }
                        handle("线性渐变终点", at: b,
                               tint: DarkroomStyle.accent) { point in
                            setLinear(1, point, rect: photoRect)
                        }
                    } else if shape.kind == .luminanceRange {
                        // Tonal ranges are selected by sampling a brightness
                        // value, rather than moving spatial gradient handles.
                        Rectangle().fill(.white.opacity(0.001))
                            .frame(width: photoRect.width, height: photoRect.height)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0,
                                            coordinateSpace: .named("mask-photo-overlay"))
                                    .onChanged { touch in
                                        draggingSamplePoint = projection.toSource(touch.location)
                                    }
                                    .onEnded { touch in
                                        draggingSamplePoint = nil
                                        chooseLuminance(touch.location)
                                    }
                            )
                            .position(x: photoRect.midX, y: photoRect.midY)
                        if let point = draggingSamplePoint {
                            luminanceCrosshair(point, brightness: nil)
                        } else if lastSampleMaskID == masks[i].id,
                                  let point = lastSamplePoint {
                            luminanceCrosshair(point, brightness: lastSampleLuma)
                        }
                    } else if shape.kind == .radialGradient {
                        let center = projection.toCanvas(shape.a)
                        let xHandle = projection.toCanvas(
                            projection.radialSourceHandle(shape, horizontal: true))
                        let yHandle = projection.toCanvas(
                            projection.radialSourceHandle(shape, horizontal: false))
                        handle("拖动径向蒙版中心", at: center,
                               tint: DarkroomStyle.accent) { point in
                            editRadial(point, rect: photoRect, axis: 0)
                        }
                        handle("调整径向蒙版宽度", at: xHandle,
                               tint: .white) { point in
                            editRadial(point, rect: photoRect, axis: 1)
                        }
                        handle("调整径向蒙版高度", at: yHandle,
                               tint: .white) { point in
                            editRadial(point, rect: photoRect, axis: 2)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .coordinateSpace(name: "mask-photo-overlay")
        .accessibilityIdentifier("InlineMaskOverlay")
    }
}
