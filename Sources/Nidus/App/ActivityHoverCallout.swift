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

extension ActivityCallout {
    /// Rows shown before the rest fold into "N more".
    static let rowLimit = 5

    /// The longest `rowLimit` items first, each with its minutes, and a
    /// footnote for what didn't fit.
    static func ranked(title: String, items: [(id: String, name: String, seconds: TimeInterval, color: Color?)],
                       empty: String = "Nothing counted") -> ActivityCallout {
        let sorted = items.filter { $0.seconds > 0 }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
        guard !sorted.isEmpty else { return ActivityCallout(title: title, rows: [], footnote: empty) }
        let rows = sorted.prefix(rowLimit).map {
            Row(id: $0.id, name: $0.name, value: ActivityDuration.string($0.seconds), color: $0.color)
        }
        let rest = sorted.count - rows.count
        return ActivityCallout(title: title, rows: rows, footnote: rest > 0 ? "\(rest) more" : nil)
    }

    /// "9:40–10:15 AM": a range in the calendar's own clock.
    static func timeRange(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: start, to: max(start, end))
    }

    /// "9–10 AM": whole hours, no minutes.
    static func hourRange(_ start: Date, calendar: Calendar = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = "j"
        return formatter.string(from: start, to: start.addingTimeInterval(3600))
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
