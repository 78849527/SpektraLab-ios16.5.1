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
            .padding(11)
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

            Slider(value: $value, in: range, step: step)
                .tint(DarkroomStyle.accent)
                .frame(minHeight: 44)
                .accessibilityLabel(label)
                .disabled(disabled)

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
        .sheet(isPresented: $showingPrecision) {
            precisionPanel
        }
    }
}
