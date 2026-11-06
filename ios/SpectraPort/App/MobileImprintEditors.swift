import SwiftUI

/// Date Back controls mirror Mac RFC-031's three imprints, two date orders,
/// four positions, physical inset and EV. Applied to preview AND export.
struct MobileDateBackEditor: View {
    @Binding var settings: MobileDateBackSettings
    let panoramic: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用日期后背", isOn: $settings.enabled)
                    .font(.system(size: 14, weight: .semibold))
                    .tint(DarkroomStyle.accent)
                    .disabled(panoramic)
                if panoramic {
                    Text("XPan / 6×12 / 6×17 没有传统日期后背；请先更换片边规格或关闭片边。")
                        .font(.system(size: 11))
                        .foregroundStyle(DarkroomStyle.secondary)
                }

                Picker("呈现", selection: $settings.face) {
                    ForEach(MobileDateBackFace.allCases) { face in
                        Text(face.rawValue).tag(face)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.enabled || panoramic)

                if settings.face != .data {
                    DatePicker("日期", selection: $settings.date,
                               displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .font(.system(size: 12))
                        .onChange(of: settings.date) { _ in
                            settings.fromEXIF = false
                        }
                    HStack(spacing: 8) {
                        Text(settings.fromEXIF ? "日期来源：照片 EXIF" : "日期来源：手动")
                        Spacer()
                        Picker("顺序", selection: $settings.order) {
                            ForEach(MobileDateBackOrder.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomStyle.secondary)
                    TextField("自定义日期字样（留空使用上方日期）",
                              text: $settings.customText)
                        .font(.system(size: 12))
                        .textFieldStyle(.roundedBorder)
                    Text("预览：" + settings.printedText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DarkroomStyle.accent)
                    Toggle("同时显示拍摄数据", isOn: $settings.withData)
                        .font(.system(size: 12))
                        .tint(DarkroomStyle.accent)
                }
                if settings.face == .data || settings.withData {
                    TextField("拍摄参数（如 f/2.8 1/125 ISO400）",
                              text: $settings.dataText)
                        .font(.system(size: 12))
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Text("位置").font(.system(size: 12))
                    Spacer()
                    Picker("位置", selection: $settings.placement) {
                        ForEach(MobileImprintPlacement.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 175)
                }
                if settings.placement == .rebate {
                    Text("片边位置仅在已启用胶片片边时生效；无片边时自动写入画面。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                HStack(spacing: 7) {
                    Text("角落").font(.system(size: 12))
                    Spacer()
                    Picker("角落", selection: $settings.corner) {
                        ForEach(MobileImprintCorner.allCases) { corner in
                            Text(corner.rawValue).tag(corner)
                        }
                    }
                    .pickerStyle(.menu)
                }
                DarkroomControlRow(label: "日期大小", value: $settings.size,
                                   range: 0.4...3, step: 0.1,
                                   suffix: "×", disabled: !settings.enabled)
                DarkroomControlRow(label: "日期亮度", value: $settings.brightnessEV,
                                   range: -2...8, step: 0.5,
                                   suffix: " EV", disabled: !settings.enabled)
                DarkroomControlRow(label: "横向边距", value: $settings.insetXMM,
                                   range: 0...30, step: 0.5,
                                   suffix: "mm", disabled: !settings.enabled)
                DarkroomControlRow(label: "纵向边距", value: $settings.insetYMM,
                                   range: 0...30, step: 0.5,
                                   suffix: "mm", disabled: !settings.enabled)
                Text("日期由相机元数据或手动输入确定；非显影阶段的日期合成不会修改胶片光谱计算。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            .padding(15)
        }
        .background(DarkroomStyle.background)
        .foregroundStyle(DarkroomStyle.primary)
    }
}

/// Draw a genuine user signature with the finger; stroke points are UVs
/// independent of the source image and export resolution.
struct MobileSignaturePad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var body: some View {
        GeometryReader { area in
            let size = area.size
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(DarkroomStyle.raised)
                Path { path in
                    for stroke in strokes + [current] where stroke.count > 1 {
                        for (index, point) in stroke.enumerated() {
                            let position = CGPoint(x: point.x*size.width,
                                                   y: point.y*size.height)
                            if index == 0 { path.move(to: position) }
                            else { path.addLine(to: position) }
                        }
                    }
                }
                .stroke(DarkroomStyle.accent,
                        style: StrokeStyle(lineWidth: 2.6,
                                           lineCap: .round, lineJoin: .round))
                Text("在这里手写")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomStyle.secondary.opacity(0.6))
                    .opacity(strokes.isEmpty && current.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let uv = CGPoint(
                            x: max(0, min(1, value.location.x / max(1,size.width))),
                            y: max(0, min(1, value.location.y / max(1,size.height))))
                        if current.last != uv && current.count < 1000 {
                            current.append(uv)
                        }
                    }
                    .onEnded { _ in
                        if current.count > 1 {
                            strokes.append(current)
                        }
                        current = []
                    }
            )
        }
        .frame(height: 148)
        .accessibilityLabel("手写签名画板")
    }
}

struct MobileSignatureEditor: View {
    @Binding var settings: MobileSignatureSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用签名", isOn: $settings.enabled)
                    .font(.system(size: 14, weight: .semibold))
                    .tint(DarkroomStyle.accent)
                Picker("方式", selection: $settings.style) {
                    ForEach(MobileSignatureStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                if settings.style == .type {
                    TextField("输入署名", text: $settings.text)
                        .font(.system(size: 13))
                        .textFieldStyle(.roundedBorder)
                    Text("艺术字体采用系统手写字体；签名写入成片而非仅显示在界面上。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                } else {
                    MobileSignaturePad(strokes: $settings.strokes)
                    HStack {
                        Text("\(settings.strokes.count) 笔")
                            .font(.system(size: 11))
                        Spacer()
                        Button("撤销一笔") {
                            if !settings.strokes.isEmpty {
                                settings.strokes.removeLast()
                            }
                        }
                        Button("清空") { settings.strokes.removeAll() }
                    }
                    .font(.system(size: 11))
                    .disabled(settings.strokes.isEmpty)
                }
                HStack {
                    Text("颜色").font(.system(size: 12))
                    Spacer()
                    Picker("颜色", selection: $settings.color) {
                        ForEach(MobileSignatureColor.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("位置").font(.system(size: 12))
                    Spacer()
                    Picker("位置", selection: $settings.corner) {
                        ForEach(MobileImprintCorner.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                }
                DarkroomControlRow(label: "签名大小", value: $settings.scale,
                                   range: 0.35...3, step: 0.05, suffix: "×",
                                   disabled: !settings.enabled)
                DarkroomControlRow(label: "不透明度", value: $settings.opacity,
                                   range: 0.05...1, step: 0.05, suffix: "",
                                   disabled: !settings.enabled)
                DarkroomControlRow(label: "水平边距", value: $settings.offsetX,
                                   range: 0...0.25, step: 0.005, suffix: "",
                                   disabled: !settings.enabled)
                DarkroomControlRow(label: "垂直边距", value: $settings.offsetY,
                                   range: 0...0.25, step: 0.005, suffix: "",
                                   disabled: !settings.enabled)
                Text("绘制的笔画按相对坐标保存；JPEG、PNG 和普通预览使用同一组签名。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            .padding(15)
        }
        .background(DarkroomStyle.background)
        .foregroundStyle(DarkroomStyle.primary)
    }
}
