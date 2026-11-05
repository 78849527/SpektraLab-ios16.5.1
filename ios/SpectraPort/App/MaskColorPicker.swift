import CoreGraphics
import SwiftUI
import UIKit

/// Mac's color-range mask selects values in the native encoded ProPhoto/ROMM
/// print, NOT in sRGB. Convert the UI colour using ColorSync-backed
/// CGColor conversion before serialising MaskComponent.color. This prevents
/// silent colour selection drift on wide-gamut photographs.
enum MaskColorConversion {
    static func display(_ romm: SIMD3<Double>) -> Color {
        guard let rommSpace = CGColorSpace(name: CGColorSpace.rommrgb),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let source = CGColor(
                colorSpace: rommSpace,
                components: [
                    CGFloat(romm.x), CGFloat(romm.y), CGFloat(romm.z), 1
                ]),
              let converted = source.converted(
                to: srgb, intent: .relativeColorimetric, options: nil),
              let channel = converted.components, channel.count >= 3 else {
            return Color(red: romm.x, green: romm.y, blue: romm.z)
        }
        return Color(
            .sRGB,
            red: Double(channel[0]), green: Double(channel[1]),
            blue: Double(channel[2]), opacity: 1
        )
    }

    static func workingValue(_ selected: Color) -> SIMD3<Double> {
        guard let romm = CGColorSpace(name: CGColorSpace.rommrgb),
              let converted = UIColor(selected).cgColor.converted(
                to: romm, intent: .relativeColorimetric, options: nil),
              let channels = converted.components,
              channels.count >= 3 else {
            return SIMD3<Double>(0.5, 0.5, 0.5)
        }
        return SIMD3<Double>(
            Double(max(0, min(1, channels[0]))),
            Double(max(0, min(1, channels[1]))),
            Double(max(0, min(1, channels[2])))
        )
    }
}

struct MaskColourRangePicker: View {
    @Binding var component: MaskComponent
    private var color: Binding<Color> {
        Binding(
            get: { MaskColorConversion.display(component.color) },
            set: { component.color = MaskColorConversion.workingValue($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorPicker("目标颜色", selection: color, supportsOpacity: false)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DarkroomStyle.primary)
            DarkroomControlRow(
                label: "颜色容差",
                value: $component.tolerance,
                range: 0.01...1.0,
                step: 0.02,
                suffix: "",
                disabled: false
            )
            Text("选择要调整的颜色，系统选色器的颜色会转换到原版光谱引擎的 ProPhoto 工作空间；并非直接在 sRGB 数值上套蒙版。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)
        }
    }
}
