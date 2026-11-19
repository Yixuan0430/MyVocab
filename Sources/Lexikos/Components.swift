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

struct DeckTile: View {
    let title: String, detail: String, glyph: String, accent: Accent
    var progress: Double?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(glyph).font(.custom("Didot", size: 22)).foregroundStyle(accent.color)
                    .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.soft))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.well)
                            Capsule().fill(accent.fill).frame(width: max(3, 140 * progress))
                        }
                        .frame(width: 140, height: 4).padding(.top, 2)
                        .accessibilityLabel("\(Int(progress * 100))%")
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.faint)
                    .opacity(hover ? 1 : 0.5)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(hover ? accent.fill : Color.lineSoft))
            .shadow(color: Color.shade.opacity(hover ? 0.09 : 0.05), radius: hover ? 16 : 10, y: hover ? 8 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityElement(children: .combine)
    }
}

struct ImportTile: View {
    let title: String, detail: String, accent: Accent
    var icon: String = "plus"
    var emphasized: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: emphasized ? .medium : .light))
                    .foregroundStyle(emphasized ? accent.color : Color.muted)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(emphasized ? accent.soft : Color.clear)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if emphasized {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.faint)
                        .opacity(hover ? 1 : 0.5)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(emphasized ? Color.panel : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                    emphasized ? (hover ? accent.fill : Color.lineSoft) : Color.line,
                    style: emphasized ? StrokeStyle(lineWidth: 1) : StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            )
            .shadow(color: emphasized ? Color.shade.opacity(hover ? 0.09 : 0.05) : .clear, radius: hover ? 16 : 10, y: hover ? 8 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}
