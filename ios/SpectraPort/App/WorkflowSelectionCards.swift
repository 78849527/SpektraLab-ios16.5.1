import SwiftUI

/// Visual vocabulary for Build 35: three stacked choice groups, each a
/// horizontally scrolling rail. Does not mutate film, RAW or mask engines.
struct WorkflowStockCard: View {
    let stockName: String
    let selected: Bool
    let isPaper: Bool
    let action: () -> Void

    private var isFuji: Bool {
        stockName.localizedCaseInsensitiveContains("fuji")
    }
    private var isKodak: Bool {
        stockName.localizedCaseInsensitiveContains("kodak") ||
        stockName.localizedCaseInsensitiveContains("portra") ||
        stockName.localizedCaseInsensitiveContains("ektacolor")
    }
    private var shortName: String {
        var text = stockName
        for prefix in ["Kodak ", "Fujifilm ", "Fuji ", "Professional "] {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count))
            }
        }
        return text
    }
    private var packageColor: Color {
        if isFuji { return Color(red: 0.16, green: 0.43, blue: 0.31) }
        if isKodak { return Color(red: 0.86, green: 0.61, blue: 0.13) }
        return Color(red: 0.39, green: 0.32, blue: 0.57)
    }

    var body: some View {
        Button(action: action) {
            // The film/paper name is only printed once, below the pack.
            // At 96x74pt, the former duplicate title and 6.5pt label
            // were too small to be usable on an actual phone.
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(packageColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isFuji ? "FUJICOLOR" : (isKodak ? "KODAK" : "FILM"))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(isPaper ? "PHOTO PAPER" : "COLOR NEGATIVE")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .padding(6)
                }
                .frame(height: 39)

                Text(shortName)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(DarkroomStyle.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(height: 22, alignment: .center)
            }
            .padding(4)
            .frame(width: 96, height: 74)
            .background(selected ? DarkroomStyle.raised : DarkroomStyle.surface,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? DarkroomStyle.accent : DarkroomStyle.line,
                            lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .top) {
                if selected {
                    Capsule()
                        .fill(DarkroomStyle.accent)
                        .frame(width: 30, height: 3)
                        .offset(y: -6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stockName + (selected ? "，已选择" : ""))
    }
}

enum WorkflowFilmEdgeChoice: String, CaseIterable, Identifiable {
    case none, f135, f120, burnished, archived, xpan, square, sixSeven, more

    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: "无片边"
        case .f135: "135 胶片条"
        case .f120: "120 中画幅"
        case .burnished: "打磨片夹"
        case .archived: "归档页"
        case .xpan: "XPan"
        case .square: "6×6"
        case .sixSeven: "6×7"
        case .more: "更多规格"
        }
    }
    var symbol: String {
        switch self {
        case .none: "square"
        case .f135: "film"
        case .f120: "rectangle"
        case .burnished: "viewfinder"
        case .archived: "square.stack.3d.up"
        case .xpan: "rectangle.expand.vertical"
        case .square: "square.dashed"
        case .sixSeven: "rectangle.dashed"
        case .more: "ellipsis"
        }
    }
    var supported: Bool { true }

    static func current(_ value: MobileFilmEdgeSettings) -> WorkflowFilmEdgeChoice {
        guard value.enabled else { return .none }
        if value.gate == .burnished { return .burnished }
        if value.view == .filed { return .archived }
        switch value.format {
        case .f135: return .f135
        case .f645: return .f120
        case .xpan: return .xpan
        case .f6x6: return .square
        case .f6x7: return .sixSeven
        default: return .more
        }
    }

    func applying(to settings: MobileFilmEdgeSettings) -> MobileFilmEdgeSettings {
        var next = settings
        next.enabled = self != .none
        next.view = .strip
        next.gate = .auto
        switch self {
        case .none: break
        case .f135: next.format = .f135
        case .f120: next.format = .f645
        case .burnished:
            next.format = .f135
            next.view = .filed
            next.gate = .burnished
        case .archived:
            next.format = .f135
            next.view = .filed
        case .xpan: next.format = .xpan
        case .square: next.format = .f6x6
        case .sixSeven: next.format = .f6x7
        case .more: break
        }
        return next
    }
}

struct WorkflowFilmEdgeCard: View {
    let option: WorkflowFilmEdgeChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(DarkroomStyle.secondary, lineWidth: 2)
                        .frame(width: 52, height: 35)
                    Image(systemName: option.symbol)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(option.supported ?
                            DarkroomStyle.primary : DarkroomStyle.secondary)
                }
                Text(option.name)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(DarkroomStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !option.supported {
                    Text("待移植")
                        .font(.system(size: 8))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
            }
            .frame(width: 96, height: 74)
            .background(selected ? DarkroomStyle.raised : DarkroomStyle.surface,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? DarkroomStyle.accent : DarkroomStyle.line,
                        lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .top) {
                if selected {
                    Capsule().fill(DarkroomStyle.accent)
                        .frame(width: 30, height: 3)
                        .offset(y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name + (selected ? "，已选择" : ""))
    }
}
