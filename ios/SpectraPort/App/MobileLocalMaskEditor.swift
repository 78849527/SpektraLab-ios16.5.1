import SwiftUI

/// Touch controls over the *original* macOS EditMask / MaskComponent model.
/// Local shapes are resolution independent; the same uniform data goes to
/// preview and full-resolution Metal passes. Brush is intentionally absent
/// until its per-mask raster is implemented and tested.
struct MobileLocalMaskEditor: View {
    @Binding var masks: [EditMask]
    let imageAspectRatio: CGFloat
    @State private var selectedID: UUID?

    private var selectedIndex: Int? {
        if let selectedID, let i = masks.firstIndex(where: { $0.id == selectedID }) {
            return i
        }
        return masks.isEmpty ? nil : 0
    }

    private func add(_ kind: MaskComponentKind) {
        guard masks.count < EditMask.maxCount else { return }
        let name: String
        switch kind {
        case .linearGradient: name = "线性渐变"
        case .radialGradient: name = "径向渐变"
        case .luminanceRange: name = "亮度范围"
        case .colorRange: name = "颜色范围"
        case .brush: return
        }
        let m = EditMask.make(kind, named: name + " " + String(masks.count + 1))
        masks.append(m)
        selectedID = m.id
    }

    private func resetSelected(_ i: Int) {
        guard masks.indices.contains(i), let kind = masks[i].components.first?.kind else { return }
        let new = EditMask.make(kind, named: masks[i].name)
        selectedID = new.id
        masks[i] = new
    }

    private func removeSelected(_ i: Int) {
        guard masks.indices.contains(i) else { return }
        masks.remove(at: i)
        selectedID = masks.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("局部调整 · macOS 同源")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Text("\(masks.count)/\(EditMask.maxCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DarkroomStyle.secondary)
            }

            HStack(spacing: 8) {
                Button { add(.linearGradient) } label: {
                    Label("线性", systemImage: "square.righthalf.filled")
                }
                Button { add(.radialGradient) } label: {
                    Label("径向", systemImage: "circle.righthalf.filled")
                }
                Button { add(.luminanceRange) } label: {
                    Label("亮度", systemImage: "sun.max")
                }
                Button { add(.colorRange) } label: {
                    Label("颜色", systemImage: "eyedropper")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(DarkroomStyle.accent)
            .disabled(masks.count >= EditMask.maxCount)

            if masks.isEmpty {
                Text("添加渐变或亮度范围后，即可独立修改局部曝光、色温、饱和度等。")
                    .font(.system(size: 12))
                    .foregroundStyle(DarkroomStyle.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(masks) { mask in
                            Button(mask.name) {
                                selectedID = mask.id
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(selectedID == mask.id ||
                                (selectedID == nil && masks.first?.id == mask.id)
                                ? DarkroomStyle.background : DarkroomStyle.primary)
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                            .background(
                                (selectedID == mask.id ||
                                 (selectedID == nil && masks.first?.id == mask.id))
                                 ? DarkroomStyle.accent : DarkroomStyle.raised,
                                in: Capsule())
                        }
                    }
                }

                if let i = selectedIndex, masks.indices.contains(i),
                   let kind = masks[i].components.first?.kind {
                    HStack {
                        Text(masks[i].name)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Toggle("启用", isOn: $masks[i].enabled)
                            .font(.system(size: 11))
                            .tint(DarkroomStyle.accent)
                            .fixedSize()
                    }
                    .foregroundStyle(DarkroomStyle.primary)

                    DarkroomControlRow(
                        label: "局部强度", value: $masks[i].amount,
                        range: 0...1, step: 0.05, suffix: "",
                        disabled: false
                    )
                    Toggle("反转区域", isOn: $masks[i].inverted)
                        .font(.system(size: 12))
                        .foregroundStyle(DarkroomStyle.primary)
                        .tint(DarkroomStyle.accent)

                    if kind == .linearGradient || kind == .radialGradient {
                        MaskGeometryPad(
                            component: $masks[i].components[0],
                            imageAspectRatio: imageAspectRatio
                        )
                            .frame(height: 178)
                        if kind == .radialGradient {
                            DarkroomControlRow(
                                label: "横向范围", value: Binding(
                                    get: { Double(masks[i].components[0].radii.width) },
                                    set: { masks[i].components[0].radii.width = $0 }),
                                range: 0.03...0.7, step: 0.01, suffix: "", disabled: false
                            )
                            DarkroomControlRow(
                                label: "纵向范围", value: Binding(
                                    get: { Double(masks[i].components[0].radii.height) },
                                    set: { masks[i].components[0].radii.height = $0 }),
                                range: 0.03...0.7, step: 0.01, suffix: "", disabled: false
                            )
                            DarkroomControlRow(
                                label: "过渡柔和度", value: $masks[i].components[0].feather,
                                range: 0...1, step: 0.05, suffix: "", disabled: false
                            )
                        }
                    } else if kind == .luminanceRange {
                        DarkroomControlRow(
                            label: "亮度下限", value: $masks[i].components[0].low,
                            range: 0...1, step: 0.02, suffix: "", disabled: false
                        )
                        DarkroomControlRow(
                            label: "亮度上限", value: $masks[i].components[0].high,
                            range: 0...1, step: 0.02, suffix: "", disabled: false
                        )
                        DarkroomControlRow(
                            label: "亮度过渡", value: $masks[i].components[0].softness,
                            range: 0...0.5, step: 0.02, suffix: "", disabled: false
                        )
                    } else if kind == .colorRange {
                        MaskColourRangePicker(component: $masks[i].components[0])
                    } else {
                        Text("此类型尚不提供触控编辑。")
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
                    }

                    Text("区域内的调整")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DarkroomStyle.primary)
                    DarkroomControlRow(
                        label: "局部曝光", value: $masks[i].adjustments.exposure,
                        range: -3...3, step: 0.1, suffix: " EV", disabled: false
                    )
                    DarkroomControlRow(
                        label: "局部色温", value: $masks[i].adjustments.temperature,
                        range: -100...100, step: 1, suffix: "", disabled: false
                    )
                    DarkroomControlRow(
                        label: "局部对比", value: $masks[i].adjustments.contrast,
                        range: -50...50, step: 1, suffix: "", disabled: false
                    )
                    DarkroomControlRow(
                        label: "局部饱和", value: $masks[i].adjustments.saturation,
                        range: -100...100, step: 1, suffix: "", disabled: false
                    )
                    DarkroomControlRow(
                        label: "局部高光", value: $masks[i].adjustments.highlights,
                        range: -100...100, step: 1, suffix: "", disabled: false
                    )
                    DarkroomControlRow(
                        label: "局部阴影", value: $masks[i].adjustments.shadows,
                        range: -100...100, step: 1, suffix: "", disabled: false
                    )

                    HStack {
                        Button("复位当前蒙版") { resetSelected(i) }
                        Spacer()
                        Button("删除蒙版", role: .destructive) { removeSelected(i) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                }
            }

            Text("这里使用照片比例下的归一化几何参数，高清渲染时不放大蒙版像素。画笔暂未开放。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)
        }
    }
}

private struct MaskGeometryPad: View {
    @Binding var component: MaskComponent
    let imageAspectRatio: CGFloat
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { area in
            let available = area.size
            let aspect = max(0.1, min(10, imageAspectRatio))
            let width = min(available.width, available.height * aspect)
            let height = width / aspect
            let origin = CGPoint(
                x: (available.width - width) / 2,
                y: (available.height - height) / 2
            )
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
            Canvas { ctx, _ in
                ctx.fill(Path(rect), with: .color(.black.opacity(0.55)))
                var grid = Path()
                for v in [CGFloat(1.0/3.0), CGFloat(2.0/3.0)] {
                    grid.move(to: CGPoint(x: origin.x + width * v, y: origin.y))
                    grid.addLine(to: CGPoint(x: origin.x + width * v, y: origin.y + height))
                    grid.move(to: CGPoint(x: origin.x, y: origin.y + height * v))
                    grid.addLine(to: CGPoint(x: origin.x + width, y: origin.y + height * v))
                }
                ctx.stroke(grid, with: .color(.gray.opacity(0.45)), lineWidth: 1)

                let gold = DarkroomStyle.accent
                func at(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: origin.x + p.x * width,
                            y: origin.y + p.y * height)
                }
                if component.kind == .linearGradient {
                    var path = Path()
                    path.move(to: at(component.a))
                    path.addLine(to: at(component.b))
                    ctx.stroke(path, with: .color(gold), lineWidth: 2)
                    for p in [component.a, component.b] {
                        let center = at(p)
                        let dot = CGRect(x: center.x - 5, y: center.y - 5,
                                         width: 10, height: 10)
                        ctx.fill(Path(ellipseIn: dot), with: .color(gold))
                    }
                } else if component.kind == .radialGradient {
                    // The original Mac shader measures radii in long-edge
                    // units. Convert to photo pixels, not the panel's aspect.
                    let r = component.radii
                    let rx = aspect >= 1 ? r.width * width : r.width / aspect * width
                    let ry = aspect >= 1 ? r.height * aspect * height : r.height * height
                    let c = at(component.a)
                    let ring = CGRect(
                        x: c.x - rx, y: c.y - ry,
                        width: rx * 2, height: ry * 2
                    )
                    ctx.stroke(Path(ellipseIn: ring), with: .color(gold),
                               lineWidth: 2)
                    ctx.fill(Path(ellipseIn: CGRect(
                        x: c.x - 4, y: c.y - 4, width: 8, height: 8
                    )), with: .color(gold))
                }
                ctx.stroke(Path(rect), with: .color(.gray.opacity(0.45)),
                           lineWidth: 1)
            }
            .frame(width: available.width, height: available.height)
            .background(DarkroomStyle.raised,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let p = CGPoint(
                            x: max(0, min(1, (drag.location.x - origin.x) / width)),
                            y: max(0, min(1, (drag.location.y - origin.y) / height))
                        )
                        if component.kind == .linearGradient {
                            if dragStart == nil {
                                dragStart = p
                                component.a = p
                            }
                            component.b = p
                        } else if component.kind == .radialGradient {
                            component.a = p
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }
}
