import SwiftUI

/// Compact controls for the original native film-edge renderer. Format names and physical
/// gate dimensions are sourced from the desktop FilmEdgeFormat model.
struct MobileFilmEdgeEditor: View {
    @Binding var settings: MobileFilmEdgeSettings
    var disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("胶片片边 · 原版引擎")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Toggle("启用片边", isOn: $settings.enabled)
                    .labelsHidden()
                    .tint(DarkroomStyle.accent)
                    .disabled(disabled)
            }
            Text("片边作为负片曝光进入原版光谱引擎；预览与高清导出使用同一组原生参数。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)

            if settings.enabled {
                HStack(spacing: 7) {
                    Text("胶片规格")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("胶片规格", selection: $settings.format) {
                        ForEach(MobileFilmEdgeFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DarkroomStyle.accent)
                    .disabled(disabled)
                }
                HStack(spacing: 7) {
                    Text("呈现")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("呈现", selection: $settings.view) {
                        ForEach(MobileFilmEdgeView.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 172)
                    .disabled(disabled)
                }
                HStack(spacing: 7) {
                    Text("片门形状")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("片门形状", selection: $settings.gate) {
                        ForEach(MobileFilmGate.allCases) { gate in
                            Text(gate.rawValue).tag(gate)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DarkroomStyle.accent)
                    .disabled(disabled)
                }
                if settings.format.perforated {
                    HStack(spacing: 7) {
                        Text("片孔")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("片孔", selection: $settings.holes) {
                            ForEach(MobileFilmEdgeHoles.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 172)
                        .disabled(disabled)
                    }
                }
                HStack(spacing: 8) {
                    Text("片号")
                        .font(.system(size: 11))
                    Spacer()
                    Stepper(
                        value: $settings.frameNumber,
                        in: 0...99, step: 1
                    ) {
                        Text(String(format: "%02d", settings.frameNumber))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DarkroomStyle.accent)
                    }
                    .fixedSize()
                    .disabled(disabled)
                }
                HStack(spacing: 8) {
                    Text("边缘文字")
                        .font(.system(size: 11))
                        .frame(width: 56, alignment: .leading)
                    TextField("默认跟随当前胶片名称", text: $settings.edgeText)
                        .font(.system(size: 11))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(disabled)
                }
                DarkroomControlRow(
                    label: "片边雾化", value: $settings.fog,
                    range: 0...4, step: 0.1, suffix: "",
                    disabled: disabled
                )
                DarkroomControlRow(
                    label: "片边漏光", value: $settings.leaks,
                    range: 0...4, step: 0.1, suffix: "",
                    disabled: disabled
                )
            }
            HStack {
                Text("使用原版引擎支持的六种片门形状。日期后背可独立启用；漏光、雾化和片号进入负片渲染。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
                Spacer(minLength: 4)
                Button("重置") { settings = MobileFilmEdgeSettings() }
                    .font(.system(size: 10))
                    .disabled(disabled)
            }
        }
        .foregroundStyle(DarkroomStyle.primary)
        .accessibilityIdentifier("MobileFilmEdgeEditor")
    }
}
