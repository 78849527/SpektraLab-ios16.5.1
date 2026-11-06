import SwiftUI

/// Touch controls over the *original* macOS EditMask / MaskComponent model.
/// Local shapes are resolution independent; the same uniform data goes to
/// preview and full-resolution Metal passes. Brush is intentionally absent
/// until its per-mask raster is implemented and tested.
struct MobileLocalMaskEditor: View {
    private enum CompactSection: String, CaseIterable, Identifiable {
        case selection = "选区"
        case light = "光线"
        case color = "色彩"
        var id: String { rawValue }
    }
    @State private var section: CompactSection = .selection

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
        section = .selection
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
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("局部蒙版")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Text(String(masks.count) + "/" + String(EditMask.maxCount))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            HStack(spacing: 4) {
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
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.bordered)
            .tint(DarkroomStyle.accent)
            .disabled(masks.count >= EditMask.maxCount)

            if masks.isEmpty {
                Text("在裁剪后的画面中移动蒙版；裁剪外的原始蒙版仍会保留。")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomStyle.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(masks) { mask in
                            let isSelected = selectedID == mask.id ||
                                (selectedID == nil && masks.first?.id == mask.id)
                            Button(mask.name) {
                                selectedID = mask.id
                                section = .selection
                            }
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ?
                                DarkroomStyle.background : DarkroomStyle.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(isSelected ? DarkroomStyle.accent : DarkroomStyle.raised,
                                        in: Capsule())
                        }
                    }
                }

                if let i = selectedIndex, masks.indices.contains(i),
                   let kind = masks[i].components.first?.kind {
                    Picker("局部调整分组", selection: $section) {
                        ForEach(CompactSection.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if section == .selection {
                        HStack {
                            Toggle("启用", isOn: $masks[i].enabled)
                                .font(.system(size: 11))
                            Spacer(minLength: 6)
                            Toggle("反转", isOn: $masks[i].inverted)
                                .font(.system(size: 11))
                        }
                        .tint(DarkroomStyle.accent)
                        .foregroundStyle(DarkroomStyle.primary)

                        DarkroomControlRow(
                            label: "蒙版强度", value: $masks[i].amount,
                            range: 0...1, step: 0.05, suffix: "", disabled: false
                        )

                        if kind == .linearGradient {
                            Text("照片上拖动黄色连线移动选区；拖动两端圆点改变范围。")
                                .font(.system(size: 10))
                                .foregroundStyle(DarkroomStyle.secondary)
                        } else if kind == .radialGradient {
                            Text("照片上拖动中心定位，拖动边缘圆点调整椭圆。")
                                .font(.system(size: 10))
                                .foregroundStyle(DarkroomStyle.secondary)
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
                                label: "过渡柔和", value: $masks[i].components[0].feather,
                                range: 0...1, step: 0.05, suffix: "", disabled: false
                            )
                        } else if kind == .luminanceRange {
                            Label("在照片上点击取样亮度；黄色十字标记取样点。", systemImage: "scope")
                                .font(.system(size: 10))
                                .foregroundStyle(DarkroomStyle.accent)
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
                        }

                        HStack(spacing: 12) {
                            Button("复位蒙版") { resetSelected(i) }
                            Spacer()
                            Button("删除蒙版", role: .destructive) { removeSelected(i) }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                    } else if section == .light {
                        VStack(spacing: 0) {
                            DarkroomControlRow(
                                label: "局部曝光", value: $masks[i].adjustments.exposure,
                                range: -3...3, step: 0.1, suffix: " EV", disabled: false
                            )
                            DarkroomControlRow(
                                label: "局部对比", value: $masks[i].adjustments.contrast,
                                range: -50...50, step: 1, suffix: "", disabled: false
                            )
                            DarkroomControlRow(
                                label: "局部高光", value: $masks[i].adjustments.highlights,
                                range: -100...100, step: 1, suffix: "", disabled: false
                            )
                            DarkroomControlRow(
                                label: "局部阴影", value: $masks[i].adjustments.shadows,
                                range: -100...100, step: 1, suffix: "", disabled: false
                            )
                        }
                    } else {
                        VStack(spacing: 0) {
                            DarkroomControlRow(
                                label: "局部色温", value: $masks[i].adjustments.temperature,
                                range: -100...100, step: 1, suffix: "", disabled: false
                            )
                            DarkroomControlRow(
                                label: "局部饱和", value: $masks[i].adjustments.saturation,
                                range: -100...100, step: 1, suffix: "", disabled: false
                            )
                        }
                    }
                }
            }
        }
    }
}
