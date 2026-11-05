import SwiftUI

private enum ColorBalanceRegion: String, CaseIterable, Identifiable {
    case master = "整体"
    case shadows = "阴影"
    case midtones = "中间调"
    case highlights = "高光"
    var id: String { rawValue }
}

/// Touch UI mapped exactly to the desktop ColorZone model. The RGB offset,
/// zone weights and luminance arithmetic are produced by the copied Mac
/// Adjustments.swift and its unchanged Shaders.metal::layer2 function.
struct MobileColorBalanceEditor: View {
    @Binding var colorBalance: ColorBalance
    @State private var region: ColorBalanceRegion = .master

    private var zone: Binding<ColorZone> {
        Binding(
            get: {
                switch region {
                case .master: return colorBalance.master
                case .shadows: return colorBalance.shadows
                case .midtones: return colorBalance.midtones
                case .highlights: return colorBalance.highlights
                }
            },
            set: { value in
                switch region {
                case .master: colorBalance.master = value
                case .shadows: colorBalance.shadows = value
                case .midtones: colorBalance.midtones = value
                case .highlights: colorBalance.highlights = value
                }
            }
        )
    }

    private func number(_ get: @escaping (ColorZone) -> Double,
                        _ set: @escaping (inout ColorZone, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { get(zone.wrappedValue) },
            set: { newValue in
                var next = zone.wrappedValue
                set(&next, newValue)
                zone.wrappedValue = next
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("分区色彩平衡")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Button("复位当前分区") {
                    zone.wrappedValue = ColorZone()
                }
                .font(.system(size: 11))
                .foregroundStyle(DarkroomStyle.accent)
            }

            HStack(spacing: 4) {
                ForEach(ColorBalanceRegion.allCases) { option in
                    Button {
                        region = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(option == region ?
                                DarkroomStyle.background : DarkroomStyle.primary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(option == region ?
                                DarkroomStyle.accent : DarkroomStyle.raised,
                                in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                ColorZoneWheel(zone: zone)
                    .frame(width: 164, height: 164)
                Spacer()
            }
            DarkroomControlRow(
                label: "色相角度", value: number({ $0.hue }, { $0.hue = $1 }),
                range: 0...360, step: 3, suffix: "°", disabled: false
            )
            DarkroomControlRow(
                label: "偏色强度", value: number({ $0.saturation }, { $0.saturation = $1 }),
                range: 0...1, step: 0.02, suffix: "", disabled: false
            )
            DarkroomControlRow(
                label: "分区明度", value: number({ $0.luminance }, { $0.luminance = $1 }),
                range: -1...1, step: 0.02, suffix: "", disabled: false
            )
            Text("色轮控制偏色方向与强度。0% 偏色是中性；可独立改变阴影、中间调和高光。")
                .font(.system(size: 10))
                .foregroundStyle(DarkroomStyle.secondary)
        }
    }
}

private struct ColorZoneWheel: View {
    @Binding var zone: ColorZone

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = side / 2 - 9
            let angle = zone.hue * .pi / 180
            let distance = min(1, max(0, zone.saturation)) * radius
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * distance,
                y: center.y - CGFloat(sin(angle)) * distance
            )

            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue,
                                     .purple, .red],
                            center: .center
                        )
                    )
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                Circle()
                    .stroke(.white.opacity(0.30), lineWidth: 1)
                Circle()
                    .fill(Color.black.opacity(0.74))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .position(point)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        let dx = Double(event.location.x - center.x)
                        let dy = Double(center.y - event.location.y)
                        let magnitude = hypot(dx, dy)
                        zone.hue = (atan2(dy, dx) * 180 / .pi + 360)
                            .truncatingRemainder(dividingBy: 360)
                        zone.saturation = min(1, max(0, magnitude / Double(radius)))
                    }
            )
            .accessibilityLabel("色彩平衡色轮")
        }
    }
}
