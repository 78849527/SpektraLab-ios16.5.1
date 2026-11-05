import SwiftUI

/// Finger-driven masks displayed in the *same* photoRect as LocalMaskCanvas.
/// The photo and handles share a single fitted geometry source, with no
/// UIScrollView, zoom restoration or independent photo aspect-fit calculation.
/// Only UI positions change; desktop EditMask, shaders and export are untouched.
struct InlineMaskOverlay: View {
    @Binding var masks: [EditMask]
    @Binding var selectedID: UUID?
    let photoRect: CGRect

    @State private var lineDragStartA: CGPoint?
    @State private var lineDragStartB: CGPoint?

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
        let value = MaskPhotoGeometry.normalized(touch, in: rect)
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
        // Move both points by the same delta and clamp the entire segment,
        // preserving direction and spacing at the photo edges.
        let dx = max(-min(a.x, b.x),
                     min(1 - max(a.x, b.x), translation.width / rect.width))
        let dy = max(-min(a.y, b.y),
                     min(1 - max(a.y, b.y), translation.height / rect.height))
        masks[i].components[0].a = CGPoint(x: a.x + dx, y: a.y + dy)
        masks[i].components[0].b = CGPoint(x: b.x + dx, y: b.y + dy)
    }

    private func editRadial(_ touch: CGPoint, rect: CGRect, axis: Int) {
        guard let i = index, masks.indices.contains(i),
              !masks[i].components.isEmpty,
              masks[i].components[0].kind == .radialGradient else { return }
        if axis == 0 {
            masks[i].components[0].a =
                MaskPhotoGeometry.normalized(touch, in: rect)
        } else {
            let shape = masks[i].components[0]
            let value = MaskPhotoGeometry.radius(
                for: touch, center: shape.a,
                angleDegrees: shape.angle, rect: rect,
                horizontal: axis == 1
            )
            if axis == 1 { masks[i].components[0].radii.width = value }
            else { masks[i].components[0].radii.height = value }
        }
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
    }

    private func draw(_ shape: MaskComponent, in rect: CGRect,
                      into context: GraphicsContext) {
        let gold = DarkroomStyle.accent
        if shape.kind == .linearGradient {
            let a = MaskPhotoGeometry.point(shape.a, in: rect)
            let b = MaskPhotoGeometry.point(shape.b, in: rect)
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            context.stroke(line, with: .color(.black.opacity(0.85)),
                           lineWidth: 5)
            context.stroke(line, with: .color(gold), lineWidth: 2)
        } else if shape.kind == .radialGradient {
            let c = MaskPhotoGeometry.point(shape.a, in: rect)
            let long = max(rect.width, rect.height)
            let rx = shape.radii.width * long
            let ry = shape.radii.height * long
            let angle = CGFloat(shape.angle * .pi / 180)
            let ca = cos(angle), sa = sin(angle)
            var boundary = Path()
            for step in 0...96 {
                let t = CGFloat(step) * .pi * 2 / 96
                let u = cos(t) * rx, v = sin(t) * ry
                let point = CGPoint(x: c.x + u * ca - v * sa,
                                    y: c.y + u * sa + v * ca)
                if step == 0 { boundary.move(to: point) }
                else { boundary.addLine(to: point) }
            }
            context.stroke(boundary, with: .color(.black.opacity(0.85)),
                           lineWidth: 5)
            context.stroke(boundary, with: .color(gold), lineWidth: 2)
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
                        let a = MaskPhotoGeometry.point(shape.a, in: photoRect)
                        let b = MaskPhotoGeometry.point(shape.b, in: photoRect)
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
                    } else if shape.kind == .radialGradient {
                        let center = MaskPhotoGeometry.point(
                            shape.a, in: photoRect)
                        let xHandle = MaskPhotoGeometry.radialHandle(
                            center: shape.a, radii: shape.radii,
                            angleDegrees: shape.angle, rect: photoRect,
                            horizontal: true)
                        let yHandle = MaskPhotoGeometry.radialHandle(
                            center: shape.a, radii: shape.radii,
                            angleDegrees: shape.angle, rect: photoRect,
                            horizontal: false)
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
