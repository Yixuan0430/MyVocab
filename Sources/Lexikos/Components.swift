import SwiftUI

extension Deck {
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, soft }
    var kind: Kind = .primary
    var accent: Accent
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, large ? 22 : kind == .soft ? 12 : 16)
            .padding(.vertical, large ? 11 : kind == .soft ? 6 : 9)
            .foregroundStyle(kind == .primary ? accent.onFill : kind == .soft ? accent.color : Color.ink)
            .background(Capsule().fill(kind == .primary ? accent.fill : kind == .soft ? accent.soft : Color.panel))
            .overlay(Capsule().strokeBorder(kind == .secondary ? Color.line : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static func capsule(_ kind: CapsuleButtonStyle.Kind = .primary, _ accent: Accent, large: Bool = false) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, accent: accent, large: large)
    }
}

extension Color {
    static var shade: Color { .dyn(0x1F2328, 0x000000) }
}

extension View {
    func paperCard(radius: CGFloat = 18, padding: CGFloat? = nil) -> some View {
        self.padding(padding ?? 0)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.lineSoft))
            .shadow(color: Color.shade.opacity(0.04), radius: 1, y: 1)
            .shadow(color: Color.shade.opacity(0.07), radius: 14, y: 8)
    }
}

struct AmbientBackground: View {
    var body: some View {
        GeometryReader { g in
            let r = max(g.size.width, g.size.height)
            ZStack {
                Color.bg
                RadialGradient(colors: [Color.warm.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: r * 0.62)
                RadialGradient(colors: [Color.cool.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: r * 0.62)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(Color.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Chip: View {
    let title: String
    var icon: String?
    let selected: Bool
    let accent: Accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                Text(title).monospacedDigit()
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(selected ? accent.onFill : Color.ink)
            .background(Capsule().fill(selected ? accent.fill : Color.well))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PaperToggle: View {
    @Binding var isOn: Bool
    let label: String
    let accent: Accent

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { isOn.toggle() } } label: {
            Capsule().fill(isOn ? accent.fill : Color.line)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.panel).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let presets: [Int]
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            step("minus", -1)
            Menu {
                ForEach(presets, id: \.self) { p in Button("\(p)") { value = p } }
            } label: {
                Text("\(value)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Color.ink)
                    .frame(minWidth: 40).padding(.vertical, 5)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            step("plus", 1)
        }
        .background(Capsule().fill(Color.well))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private func step(_ icon: String, _ d: Int) -> some View {
        Button { value = min(range.upperBound, max(range.lowerBound, value + d)) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.muted)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(d < 0 ? value <= range.lowerBound : value >= range.upperBound)
    }
}

struct SearchBox: View {
    @Binding var text: String
    let prompt: String
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.faint)
            if snapshotting {
                Text(text.isEmpty ? prompt : text).font(.system(size: 12.5)).foregroundStyle(text.isEmpty ? Color.faint : Color.ink)
                Spacer(minLength: 0)
            } else {
                TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.faint) }
                        .buttonStyle(.plain).accessibilityLabel("Clear")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.well))
    }
}
