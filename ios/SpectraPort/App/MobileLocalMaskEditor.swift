import SwiftUI

/// Touch controls over the *original* macOS EditMask / MaskComponent model.
/// Local shapes are resolution independent; the same uniform data goes to
/// preview and full-resolution Metal passes. Brush is intentionally absent
/// until its per-mask raster is implemented and tested.
struct MobileLocalMaskEditor: View {
    @Binding var masks: [EditMask]
    /// One selection shared with the handles shown over the photo preview.
    @Binding var selectedID: UUID?

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
                        Text(kind == .linearGradient
                            ? "在上方照片拖动黄色连线可移动整个渐变；拖动两端圆点可调整方向和范围。"
                            : "在上方照片拖动中心圆点定位椭圆，拖动两侧圆点改变宽度与高度。")
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
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

            Text("局部位置直接在上方照片上操作；下方调整区域参数。蒙版坐标与导出分辨率无关，画笔暂未开放。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)
        }
    }
}

