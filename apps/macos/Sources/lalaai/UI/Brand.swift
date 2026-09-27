import AppKit
import SwiftUI

// MARK: - Components

/// Pill buttons: primary (brand gradient), secondary (tinted), danger (warm), ghost (plain).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .primary
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 17 : 13, weight: .bold, design: .rounded))
            .padding(.horizontal, large ? 28 : 16)
            .padding(.vertical, large ? 14 : 9)
            .frame(minHeight: large ? 52 : 36)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .ghost ? Color.secondary.opacity(0.25) : .clear, lineWidth: 1))
            .shadow(color: kind == .primary ? Color.brandNavy.opacity(0.25) : .clear, radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return scheme == .dark ? .brandNavy : .white
        case .secondary: return .brandPrimary
        case .danger: return .white
        case .ghost: return .primary
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary:
            return scheme == .dark
                ? AnyShapeStyle(LinearGradient(colors: [Color.brandAqua, Color(red: 0.49, green: 0.85, blue: 0.99)], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(LinearGradient(colors: [Color.brandNavy, Color(red: 0.05, green: 0.25, blue: 0.55)], startPoint: .leading, endPoint: .trailing))
        case .secondary: return AnyShapeStyle(Color.brandAqua.opacity(scheme == .dark ? 0.22 : 0.18))
        case .danger: return AnyShapeStyle(LinearGradient(colors: [.brandWarmLight, .brandWarm], startPoint: .leading, endPoint: .trailing))
        case .ghost: return AnyShapeStyle(Color.clear)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind = .primary, large: Bool = false) -> PillButtonStyle { PillButtonStyle(kind: kind, large: large) }
}

/// A rounded content card with a title row.
struct Card<Content: View>: View {
    var title: String
    var icon: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.brandPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.brandAqua.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

/// Selectable pill chip (language, provider, mode).
struct Chip: View {
    var label: String
    var leading: String? = nil
    var systemImage: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let leading { Text(leading) }
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
                Text(label).lineLimit(1)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(selected ? Color.brandPrimary : .primary)
            .background(selected ? Color.brandAqua.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.brandAqua.opacity(0.9) : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

/// Segmented pills for small enums.
struct PillPicker<T: Hashable & Identifiable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var icon: ((T) -> String)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { o in
                let on = o == selection
                Button { selection = o } label: {
                    HStack(spacing: 6) {
                        if let icon { Image(systemName: icon(o)).font(.system(size: 11, weight: .bold)) }
                        Text(label(o))
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(on ? (scheme == .dark ? Color.brandNavy : Color.white) : .primary)
                    .background(on ? AnyShapeStyle(Color.brandPrimary) : AnyShapeStyle(Color.clear), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .animation(.snappy(duration: 0.18), value: selection)
    }
}

/// Large rounded text field.
struct BigField: View {
    var placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 15, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Text with an outline, readable on any background (used by transparent floating windows).
struct OutlinedText: View {
    var text: String
    var font: Font
    var fill: Color = .white
    var outline: Color = .black
    var width: CGFloat = 2
    var alignment: TextAlignment = .leading

    var body: some View {
        let base = Text(text).font(font).multilineTextAlignment(alignment)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                base.foregroundStyle(outline).offset(x: cos(a) * width, y: sin(a) * width)
            }
            base.foregroundStyle(fill)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
