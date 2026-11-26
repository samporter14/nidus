//
//  ActivityHoverCallout.swift
//  Nidus
//
//  The one hover readout every Activity chart shares: a small raised card
//  near the pointer, the time range first, then each category or app with its
//  minutes in figures that line up. It replaces the one-line readouts that
//  truncated under the ribbon, the week glance, the heatmap and the bars.
//  Never hit-testable: it follows the pointer, it doesn't catch it.
//

import SwiftUI

/// What a callout says.
struct ActivityCallout: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        /// "1h 20m", already formatted (ActivityDuration.string).
        var value: String
        /// The row's swatch; nil for none (a total, a note).
        var color: Color?
    }

    /// The time range or the day: "Tue 9–10 AM", "Monday 12 May".
    var title: String
    var rows: [Row]
    /// One quiet line under the rows ("2 more"), optional.
    var footnote: String? = nil

    /// The same, read by VoiceOver in one breath.
    var spoken: String {
        ([title] + rows.map { "\($0.name), \($0.value)" } + [footnote].compactMap { $0 }).joined(separator: ". ")
    }
}

struct ActivityHoverCalloutView: View {
    let callout: ActivityCallout
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(callout.title)
                .font(.solanum(.caption, weight: .semibold))
                .foregroundStyle(Solanum.ink)
            ForEach(callout.rows) { row in
                HStack(spacing: 6) {
                    if let color = row.color {
                        RoundedRectangle(cornerRadius: Solanum.markRadius).fill(color).frame(width: 8, height: 8)
                    }
                    Text(verbatim: row.name)
                        .foregroundStyle(Solanum.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(verbatim: row.value)
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.solanum(.caption))
            }
            if let footnote = callout.footnote {
                Text(verbatim: footnote)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 140, maxWidth: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Solanum.raised, in: .rect(cornerRadius: Solanum.frameRadius))
        .overlay(RoundedRectangle(cornerRadius: Solanum.frameRadius).strokeBorder(Solanum.edge(contrast)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shows `callout` near `point` (in this view's coordinates), above the
    /// pointer when there is room and below it otherwise, kept inside the
    /// view's width. Pass nil for either to hide it. Draws over neighbours:
    /// give the chart's card a `zIndex` while it hovers if a later sibling
    /// would cover it.
    func activityHoverCallout(_ callout: ActivityCallout?, at point: CGPoint?) -> some View {
        modifier(ActivityHoverCalloutPlacement(callout: callout, point: point))
    }
}

private struct ActivityHoverCalloutPlacement: ViewModifier {
    let callout: ActivityCallout?
    let point: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                if let callout, let point {
                    ActivityHoverCalloutView(callout: callout)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .offset(Self.offset(for: point, callout: size, in: proxy.size))
                }
            }
        }
    }

    /// Where the callout's top-left corner goes: 12 pt right of the pointer
    /// (or left of it near the right edge), 10 pt above it (or below it near
    /// the top).
    static func offset(for point: CGPoint, callout: CGSize, in bounds: CGSize) -> CGSize {
        var x = point.x + 12
        if x + callout.width > bounds.width { x = point.x - 12 - callout.width }
        x = min(max(0, x), max(0, bounds.width - callout.width))
        var y = point.y - 10 - callout.height
        if y < -callout.height / 2 { y = point.y + 14 }
        return CGSize(width: x, height: y)
    }
}
