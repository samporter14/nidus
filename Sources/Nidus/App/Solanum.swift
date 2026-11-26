// Solanum.swift — Nidus in Solanum, the company's design system
// (https://claude.ai/artifact/BjQZQTY4NYmLcz39pHWmQE): its colours in both
// themes, and the pieces the popover, the cards and Settings are built from.
// Structure comes from hairline borders, not shadows; clay is a fill, and
// clay words use `clayText`. Text on a clay fill is `onClay`. The colours,
// chart palette and type scale are in SolanumTokens.swift (the widget shares
// that file); this one holds the pieces built from them.
import AppKit
import SwiftUI

/// A section's label: mono, uppercase, letterspaced, faint. Never a sentence.
struct Overline: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.solanum(.overline))
            .tracking(0.9)
            .foregroundStyle(Solanum.inkFaint)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A raised card with a hairline edge (a firmer one under Increased
    /// Contrast).
    func solanumCard(radius: CGFloat = 12) -> some View {
        modifier(SolanumCardSurface(radius: radius))
    }

    /// The one empty-state pattern for a chart: its real frame drawn faintly,
    /// and one line saying what will fill it. The faint chart is hidden from
    /// VoiceOver, which reads the line.
    func chartEmptyState(_ isEmpty: Bool, _ message: String) -> some View {
        modifier(ChartEmptyState(isEmpty: isEmpty, message: message))
    }

    /// Data arriving: fades in over 0.2 s once, when `shown` turns true.
    /// Instant under Reduce Motion.
    func dataFadeIn(_ shown: Bool) -> some View {
        modifier(DataFadeIn(shown: shown))
    }
}

private struct SolanumCardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Solanum.raised, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Solanum.edge(contrast)))
    }
}

private struct ChartEmptyState: ViewModifier {
    let isEmpty: Bool
    let message: String

    func body(content: Content) -> some View {
        if isEmpty {
            content
                .opacity(0.35)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay {
                    Text(message)
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Solanum.raised.opacity(0.85), in: .rect(cornerRadius: Solanum.frameRadius))
                }
        } else {
            content
        }
    }
}

private struct DataFadeIn: ViewModifier {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
    }
}

/// A 4 pt magnitude bar: how big a row is next to the biggest, on an empty
/// track. Lists of ranked things (categories, apps, sites, drift) share it.
struct SolanumMagnitudeBar: View {
    /// 0 to 1; anything above 1 is drawn full.
    let fraction: Double
    let color: Color
    var opacity: Double = 0.85
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Solanum.track(contrast))
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(Solanum.fillOpacity(opacity, contrast)))
                        .frame(width: Swift.max(4, proxy.size.width * Swift.min(1, Swift.max(0, fraction))))
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
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
                    .font(.solanum(.title, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                if let hint {
                    Text(hint)
                        .font(.solanum(.label, weight: .regular))
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
                        .font(.solanum(.body, weight: .medium))
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
            .font(.solanum(.body, weight: .medium))
            .foregroundStyle(isEnabled ? Solanum.ink : Solanum.inkFaint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(SolanumButtonSurface(primary: false, pressed: configuration.isPressed))
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
            .modifier(SolanumButtonSurface(primary: true, pressed: configuration.isPressed))
    }
}

/// Pointer and focus feedback is local to a mounted control. No animation,
/// tracking loop or retained UI is needed after its window closes.
private struct SolanumButtonSurface: ViewModifier {
    let primary: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.controlSize) private var size
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .frame(minHeight: size == .small || size == .mini ? 24 : 28)
            .background {
                if primary {
                    shape.fill(Solanum.clay.opacity(enabled ? 1 : 0.4))
                        .brightness(enabled ? (pressed ? -0.08 : hovered ? 0.04 : 0) : 0)
                } else {
                    shape.fill(enabled && (pressed || hovered) ? Solanum.segmentWell : Solanum.raised)
                }
            }
            .overlay {
                shape.strokeBorder(focused ? Solanum.clayText : primary ? Solanum.hairline
                                   : enabled ? Solanum.strong : Solanum.hairline,
                                   lineWidth: focused ? 2 : 1)
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
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
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Solanum.clayText : Solanum.strong,
                                                                   lineWidth: focused ? 2 : 1))
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
