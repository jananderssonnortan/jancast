import SwiftUI

/// Grouped content surface matching System Settings' inset groups.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Status glyph: always shape + color, never color alone.
struct HealthIcon: View {
    let health: Health
    var body: some View {
        Group {
            if health == .neutral {
                Image(systemName: health.symbol).foregroundStyle(.secondary)
            } else {
                Image(systemName: health.symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(health == .warning ? Color.black.opacity(0.75) : .white, health.color)
            }
        }
        .imageScale(.medium)
        .accessibilityLabel(Text(String(describing: health)))
    }
}

struct PhaseBadge: View {
    let phase: Phase
    var body: some View {
        Label(phase.title, systemImage: phase.symbol)
            .font(.callout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(phase.color == .secondary ? Color.secondary : phase.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(phase.color.opacity(0.14), in: Capsule())
    }
}

/// Little legend swatch used in chart headers.
struct LegendSwatch: View {
    enum Kind { case line, area, dashed, block, cross }
    let kind: Kind
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Group {
                switch kind {
                case .line:
                    Capsule().fill(color).frame(width: 14, height: 2.5)
                case .area:
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.3)).frame(width: 12, height: 9)
                case .dashed:
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 14, height: 2)
                case .block:
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.35)).frame(width: 9, height: 9)
                case .cross:
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(color)
                }
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }
}

/// Callout used to explain consequences in plain words.
struct Callout: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
