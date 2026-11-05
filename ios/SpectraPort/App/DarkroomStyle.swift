import SwiftUI

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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DarkroomStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(DarkroomStyle.line, lineWidth: 1)
            )
    }
}

struct DarkroomSectionTitle: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(DarkroomStyle.accent)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
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
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DarkroomStyle.background : DarkroomStyle.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
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
    let action: () -> Void

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

                Spacer(minLength: 10)

                Text(detail)
                    .font(.system(size: 16, weight: .semibold))
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
                    Text("NEGATIVE")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .opacity(0.7)
                }
            }
            .padding(12)
            .foregroundStyle(selected ? DarkroomStyle.background : DarkroomStyle.primary)
            .frame(width: 166, height: 120, alignment: .leading)
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

struct DarkroomControlRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let disabled: Bool

    private func adjust(_ amount: Double) {
        let result = min(range.upperBound, max(range.lowerBound, value + amount))
        // Snap to the parameter's actual step to avoid drift after repeated taps.
        let steps = ((result - range.lowerBound) / step).rounded()
        value = min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Text(String(format: "%.2f", value) + suffix)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(DarkroomStyle.accent)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Button { adjust(-step) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label + "减少")
                Slider(value: $value, in: range, step: step)
                    .tint(DarkroomStyle.accent)
                Button { adjust(step) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label + "增加")
            }
            .foregroundStyle(DarkroomStyle.secondary)
            .disabled(disabled)
        }
    }
}
