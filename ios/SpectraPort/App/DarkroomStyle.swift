import SwiftUI
import UIKit

/// Local visual system only. Keeps the original engine and image colour
/// management separate from the editor's neutral dark chrome.
enum DarkroomStyle {
    static let background = Color(red: 0.055, green: 0.064, blue: 0.072)
    static let surface = Color(red: 0.105, green: 0.116, blue: 0.127)
    static let raised = Color(red: 0.155, green: 0.166, blue: 0.176)
    static let line = Color.white.opacity(0.09)
    static let accent = Color(red: 0.91, green: 0.74, blue: 0.48)
    static let primary = Color(red: 0.95, green: 0.94, blue: 0.92)
    static let secondary = Color(red: 0.65, green: 0.67, blue: 0.68)
}

struct DarkroomPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DarkroomStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DarkroomStyle.line, lineWidth: 1)
            )
    }
}

struct DarkroomSectionTitle: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DarkroomStyle.accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DarkroomStyle.primary)
            Spacer(minLength: 4)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(DarkroomStyle.secondary)
                .lineLimit(1)
        }
    }
}

struct DarkroomChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DarkroomStyle.background : DarkroomStyle.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    selected ? DarkroomStyle.accent : DarkroomStyle.raised,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct FilmStockCard: View {
    let name: String
    let selected: Bool
    let kind: String
    let action: () -> Void

    init(name: String, selected: Bool, kind: String = "NEGATIVE",
         action: @escaping () -> Void) {
        self.name = name
        self.selected = selected
        self.kind = kind
        self.action = action
    }

    private var brand: String {
        if name.lowercased().contains("fujifilm") { return "FUJIFILM" }
        if name.lowercased().contains("kodak") { return "KODAK" }
        return "FILM"
    }

    private var detail: String {
        let prefix = name.lowercased().contains("fujifilm") ? "Fujifilm " : "Kodak "
        return name.replacingOccurrences(of: prefix, with: "")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(selected ? DarkroomStyle.background : DarkroomStyle.accent)
                        .frame(width: 5, height: 5)
                    Text(brand)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(1.5)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                    }
                }
                .opacity(selected ? 0.82 : 0.75)

                Spacer(minLength: 6)

                Text(detail)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(selected ? DarkroomStyle.background.opacity(0.34) : DarkroomStyle.secondary.opacity(0.36))
                            .frame(width: 9, height: 3)
                    }
                    Spacer()
                    Text(kind)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .opacity(0.7)
                }
            }
            .padding(12)
            .foregroundStyle(selected ? DarkroomStyle.background : DarkroomStyle.primary)
            .frame(width: 145, height: 102, alignment: .leading)
            .background(
                selected ? DarkroomStyle.accent : DarkroomStyle.raised,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        selected ? DarkroomStyle.accent : DarkroomStyle.line,
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + (selected ? "，已选中" : ""))
    }
}

/// One-line Lightroom-style control: 44pt touch target despite compact
/// typography. Tapping the value opens step-accurate precision controls.
struct DarkroomControlRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let disabled: Bool

    @State private var showingPrecision = false
    @State private var precisionText = ""
    @State private var isDragging = false

    private var decimals: Int {
        if step < 0.01 { return 3 }
        if step < 1 { return 2 }
        return 0
    }

    private func formatted(_ number: Double) -> String {
        String(format: "%.*f", decimals, number)
    }

    private var maximumStepIndex: Int {
        Int(((range.upperBound - range.lowerBound) / step).rounded())
    }

    private var currentStepIndex: Int {
        let raw = Int(((value - range.lowerBound) / step).rounded())
        return min(maximumStepIndex, max(0, raw))
    }

    private func adjust(direction: Int) {
        guard !disabled else { return }
        let target = min(maximumStepIndex, max(0, currentStepIndex + direction))
        value = min(range.upperBound, max(range.lowerBound,
            range.lowerBound + Double(target) * step))
        precisionText = formatted(value)
    }

    private func applyPreciseNumber() {
        let text = precisionText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if let proposed = Double(text), proposed.isFinite {
            let steps = ((proposed - range.lowerBound) / step).rounded()
            let snapped = range.lowerBound + steps * step
            value = min(range.upperBound, max(range.lowerBound, snapped))
        }
        showingPrecision = false
    }

    private var precisionPanel: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(label + " · 精确调整")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DarkroomStyle.primary)
                HStack(spacing: 12) {
                    Button { adjust(direction: -1) } label: {
                        Image(systemName: "minus")
                            .frame(width: 44, height: 44)
                            .background(DarkroomStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(disabled || currentStepIndex == 0)

                    TextField("数值", text: $precisionText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .padding(.vertical, 9)
                        .background(DarkroomStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(label + " 数值输入")

                    Button { adjust(direction: 1) } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                            .background(DarkroomStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(disabled || currentStepIndex == maximumStepIndex)
                }
                .foregroundStyle(DarkroomStyle.primary)
                .buttonStyle(.plain)
                Text("允许范围 " + formatted(range.lowerBound) + " ～ " +
                     formatted(range.upperBound) + suffix)
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomStyle.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(DarkroomStyle.background.ignoresSafeArea())
            .navigationTitle("精确调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingPrecision = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { applyPreciseNumber() }
                        .disabled(disabled)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(270)])
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DarkroomStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 77, alignment: .leading)
                .accessibilityAddTraits(.isStaticText)

            CompactFineSlider(
                value: $value, range: range, step: step,
                disabled: disabled, label: label,
                onTrackingChange: { isDragging = $0 }
            )
            .frame(height: 44)
            .accessibilityLabel(label)

            Button {
                precisionText = formatted(value)
                showingPrecision = true
            } label: {
                Text(formatted(value) + suffix)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DarkroomStyle.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 76, alignment: .trailing)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(label + " 精确输入")
            .accessibilityValue(formatted(value) + suffix)
        }
        .frame(minHeight: 44)
        .preference(
            key: CompactSliderReadoutKey.self,
            value: isDragging ? label + "  " + formatted(value) + suffix : nil
        )
        .sheet(isPresented: $showingPrecision) {
            precisionPanel
        }
    }
}


/// A precise UISlider whose visual track is 2pt and thumb is 10pt (12pt on
/// touch). UIKit retains its native gesture interaction within ScrollView.
private struct CompactFineSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let disabled: Bool
    let label: String
    let onTrackingChange: (Bool) -> Void

    private static func trackImage(_ color: UIColor) -> UIImage {
        let width: CGFloat = 12
        let height: CGFloat = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                         cornerRadius: height / 2).fill()
        }
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 5),
            resizingMode: .stretch
        )
    }

    private static func thumbImage(diameter: CGFloat) -> UIImage {
        let canvas = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            let rect = CGRect(x: (canvas.width - diameter) / 2,
                              y: (canvas.height - diameter) / 2,
                              width: diameter, height: diameter)
            UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor(red: 0.62, green: 0.49, blue: 0.33, alpha: 0.9).setStroke()
            let edge = UIBezierPath(ovalIn: rect.insetBy(dx: 0.45, dy: 0.45))
            edge.lineWidth = 0.8
            edge.stroke()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.setMinimumTrackImage(Self.trackImage(
            UIColor(red: 0.91, green: 0.74, blue: 0.48, alpha: 1)), for: .normal)
        slider.setMaximumTrackImage(Self.trackImage(
            UIColor(white: 0.54, alpha: 0.64)), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 10), for: .normal)
        slider.setThumbImage(Self.thumbImage(diameter: 12), for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)),
                         for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.started(_:)),
                         for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.owner = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.isEnabled = !disabled
        // Keep the native thumb in contact with the finger while dragging.
        if !slider.isTracking {
            slider.setValue(Float(min(range.upperBound, max(range.lowerBound, value))),
                            animated: false)
        }
        slider.accessibilityLabel = label
        slider.accessibilityValue = String(format: "%.2f", value)
    }

    final class Coordinator: NSObject {
        var owner: CompactFineSlider
        init(_ owner: CompactFineSlider) { self.owner = owner }

        @objc func started(_ slider: UISlider) {
            owner.onTrackingChange(true)
        }

        @objc func changed(_ slider: UISlider) {
            let raw = Double(slider.value)
            let steps = ((raw - owner.range.lowerBound) / owner.step).rounded()
            let snapped = min(owner.range.upperBound,
                              max(owner.range.lowerBound,
                                  owner.range.lowerBound + steps * owner.step))
            if owner.value != snapped { owner.value = snapped }
        }

        @objc func ended(_ slider: UISlider) {
            changed(slider)
            owner.onTrackingChange(false)
        }
    }
}

/// The active slider's HUD is forwarded from the bottom adjustment panel to
/// the photo preview, without coupling it to the original rendering engine.
struct CompactSliderReadoutKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

