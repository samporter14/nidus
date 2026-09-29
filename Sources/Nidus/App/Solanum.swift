// Solanum.swift — Nidus in Solanum, the company's design system
// (https://claude.ai/artifact/BjQZQTY4NYmLcz39pHWmQE): its colours in both
// themes, and the pieces the popover, the cards and Settings are built from.
// Structure comes from hairline borders, not shadows; clay is a fill, and
// clay words use `clayText`. Text on a clay fill is `onClay`.
import AppKit
import SwiftUI

enum Solanum {
    /// Ivory in light, slate in dark: the ground of every tab.
    static let page = adaptive(light: 0xFAF9F5, dark: 0x141413)
    /// Cards on the page.
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x262625)
    static let ink = adaptive(light: 0x141413, dark: 0xFAF9F5)
    /// Hints and secondary words. 6.3:1 light, 8.4:1 dark.
    static let inkMuted = adaptive(light: 0x5E5D59, dark: 0xB0AEA5)
    /// Mono overlines only, 11 pt and up, on the page.
    static let inkFaint = adaptive(light: 0x73726C, dark: 0x91918D)
    static let hairline = adaptive(light: (31, 30, 29, 0.15), dark: (250, 249, 245, 0.18))
    /// Control borders and focus rings.
    static let strong = adaptive(light: (31, 30, 29, 0.3), dark: (250, 249, 245, 0.32))
    /// The accent, as a fill only: 2.96:1 on the page, so never text.
    static let clay = Color(nsColor: NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1))
    /// Words and symbols on a clay fill: ink, in both themes (6:1).
    static let onClay = Color(nsColor: NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 1))
    /// Clay read as words: clay itself is too faint for text.
    static let clayText = adaptive(light: 0x9C4221, dark: 0xE4927A)
    /// The raised segment of a segmented control, and its well.
    static let segmentOn = adaptive(light: 0xFFFFFF, dark: 0x3A3935)
    static let segmentWell = adaptive(light: (31, 30, 29, 0.06), dark: (250, 249, 245, 0.08))

    /// Serif for display (the system's New York), sans for reading.
    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }

    private static func adaptive(light: Int, dark: Int) -> Color {
        adaptive(light: rgb(light), dark: rgb(dark))
    }

    private static func adaptive(light: (Int, Int, Int, Double), dark: (Int, Int, Int, Double)) -> Color {
        adaptive(light: rgba(light), dark: rgba(dark))
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgba(_ c: (Int, Int, Int, Double)) -> NSColor {
        NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: c.3)
    }
}

/// A section's label: mono, uppercase, letterspaced, faint. Never a sentence.
struct Overline: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(Solanum.inkFaint)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A raised card with a hairline edge.
    func solanumCard(radius: CGFloat = 12) -> some View {
        background(Solanum.raised, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Solanum.hairline))
    }
}

/// One line of a settings card: a title and a hint, and its control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Solanum.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(minHeight: 52)
    }
}

/// Rows in one card, split by hairlines.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Solanum.hairline).frame(height: 1) }
                    row
                }
            }
        }
        .solanumCard()
    }
}

/// A segmented control in Solanum: a hairline well with the chosen segment
/// raised, no accent colour.
struct SolanumSegmented<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> Label
    var accessibilityName: String = ""

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    label(option)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? Solanum.ink : Solanum.inkMuted)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Solanum.segmentOn)
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Solanum.hairline))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Solanum.segmentWell, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Solanum.hairline))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}

/// A plain bordered button in Solanum.
struct SolanumButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Solanum.ink : Solanum.inkFaint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Solanum.segmentWell : Solanum.raised, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isEnabled ? Solanum.strong : Solanum.hairline))
    }
}

/// The one action that matters: a clay fill with ink words.
struct SolanumPrimaryButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Solanum.onClay.opacity(isEnabled ? 1 : 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Solanum.clay.opacity(isEnabled ? 1 : 0.4), in: .rect(cornerRadius: 8))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(.rect(cornerRadius: 8))
    }
}

/// A symbol on a small clay tile: a card's or a row's mark.
struct SolanumTile: View {
    let image: Image
    var size: CGFloat = 28
    /// Raised with a hairline and an ink symbol, for what isn't news.
    var quiet = false

    init(symbol: String, size: CGFloat = 28, quiet: Bool = false) {
        image = Image(systemName: symbol)
        self.size = size
        self.quiet = quiet
    }

    init(image: Image, size: CGFloat = 28) {
        self.image = image
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(quiet ? Solanum.raised : Solanum.clay)
            .overlay {
                if quiet {
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(Solanum.hairline)
                }
            }
            .overlay(
                image
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(quiet ? Solanum.ink : Solanum.onClay)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A text field in Solanum: raised, a control border, thicker when focused.
struct SolanumFieldStyle: ViewModifier {
    var fontSize: CGFloat = 13
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .foregroundStyle(Solanum.ink)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Solanum.raised, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Solanum.strong, lineWidth: focused ? 2 : 1))
    }
}

extension View {
    func solanumField(fontSize: CGFloat = 13) -> some View { modifier(SolanumFieldStyle(fontSize: fontSize)) }
}

/// Lays its children out in rows, wrapping to the next when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
