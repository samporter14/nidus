//
//  ActivityWeekGlance.swift
//  Nidus
//
//  A stacked bar per day, then each category's week against the one before.
//  Drawn in one Canvas, with an entry per day for VoiceOver. It changes only
//  when a saved day does. Clicking a day opens it.
//

import SwiftUI

struct ActivityWeekGlance: View {
    let week: ActivityWeek
    var calendar: Calendar = .current
    let openDay: (Date) -> Void

    @State private var hovered: Int?
    @State private var pointer: CGPoint?
    @Environment(\.colorSchemeContrast) private var contrast

    private let chartHeight: CGFloat = 96
    private let gap: CGFloat = 8

    static let emptyMessage = "Each day's bar fills in as the week goes"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                chart
                    .activityHoverCallout(callout, at: pointer)
                    .zIndex(callout == nil ? 0 : 1)
                labels
            }
            .chartEmptyState(week.isEmpty, Self.emptyMessage)
            if !week.isEmpty {
                Divider()
                totals
            }
        }
    }

    /// The hovered day, for the shared callout.
    private var callout: ActivityCallout? {
        guard let hovered, week.days.indices.contains(hovered) else { return nil }
        return Self.callout(of: week.days[hovered])
    }

    static func callout(of day: ActivityWeek.Day) -> ActivityCallout {
        .ranked(title: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                items: day.parts.map { ($0.id, $0.name, $0.seconds, ActivityInk.series($0.tint)) })
    }

    private var chart: some View {
        let peak = week.peak
        return GeometryReader { proxy in
            Canvas { context, size in
                let width = (size.width - gap * CGFloat(week.days.count - 1)) / CGFloat(week.days.count)
                for (index, day) in week.days.enumerated() {
                    let x = CGFloat(index) * (width + gap)
                    let track = CGRect(x: x, y: 0, width: width, height: size.height)
                    let shape = Path(roundedRect: track, cornerRadius: Solanum.markRadius, style: .continuous)
                    context.fill(shape, with: .color(Solanum.track(contrast)))
                    var bottom = size.height
                    context.drawLayer { layer in
                        layer.clip(to: shape)
                        for part in day.parts {
                            let height = size.height * part.seconds / peak
                            layer.fill(Path(CGRect(x: x, y: bottom - height, width: width, height: height)),
                                       with: .color(ActivityInk.series(part.tint)))
                            bottom -= height
                        }
                    }
                    if hovered == index {
                        context.stroke(shape, with: .color(Solanum.ink.opacity(0.4)), lineWidth: 1)
                    } else if contrast == .increased {
                        context.stroke(shape, with: .color(Solanum.edge(contrast)), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = dayIndex(at: point, width: proxy.size.width)
                    if index != hovered { hovered = index }
                    pointer = index == nil ? nil : point
                case .ended:
                    if hovered != nil { hovered = nil }
                    pointer = nil
                }
            }
            .onTapGesture { point in
                if let index = dayIndex(at: point, width: proxy.size.width) { openDay(week.days[index].date) }
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time by day and category")
        .accessibilityChildren {
            ForEach(week.days) { day in
                Rectangle()
                    .accessibilityLabel(summary(of: day))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens this day")
                    .accessibilityAction { openDay(day.date) }
            }
        }
    }

    private func dayIndex(at point: CGPoint, width: CGFloat) -> Int? {
        let index = Int(point.x / max(1, width / CGFloat(week.days.count)))
        return week.days.indices.contains(index) ? index : nil
    }

    private var labels: some View {
        HStack(spacing: gap) {
            ForEach(week.days) { day in
                VStack(spacing: 1) {
                    Text(verbatim: name(of: day))
                        .font(.solanum(.caption, weight: .medium))
                        .foregroundStyle(Solanum.inkFaint)
                    Text(day.parts.isEmpty ? "\u{2013}" : ActivityDuration.string(day.seconds))
                        .font(.solanum(.caption, design: .rounded))
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(week.deltas) { delta in
                HStack(spacing: 6) {
                    Circle().fill(ActivityInk.series(delta.tint)).frame(width: 6, height: 6)
                    Text(verbatim: delta.name)
                        .foregroundStyle(Solanum.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ActivityDuration.string(delta.thisWeek))
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                    if week.hasLastWeek {
                        Text(verbatim: delta.changeText)
                            .foregroundStyle(Solanum.inkMuted)
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                .font(.solanum(.caption))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description(of: delta))
            }
            if !week.hasLastWeek {
                Text("Nothing to compare with yet: the seven days before are empty.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
            }
        }
    }

    private func name(of day: ActivityWeek.Day) -> String {
        calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day.date) - 1]
    }

    private static func parts(of day: ActivityWeek.Day) -> [String] {
        day.parts.sorted { $0.seconds > $1.seconds }.map { "\($0.name) \(ActivityDuration.string($0.seconds))" }
    }

    private func summary(of day: ActivityWeek.Day) -> String {
        let name = day.date.formatted(date: .complete, time: .omitted)
        guard !day.parts.isEmpty else { return "\(name), nothing counted" }
        return ([name, ActivityDuration.string(day.seconds)] + Self.parts(of: day)).joined(separator: ", ")
    }

    private func description(of delta: ActivityWeek.Delta) -> String {
        let total = "\(delta.name), \(ActivityDuration.string(delta.thisWeek)) in these seven days"
        guard week.hasLastWeek else { return total }
        if abs(delta.change) < 60 { return total + ", about the same as the seven before" }
        return total + ", \(ActivityDuration.string(abs(delta.change))) \(delta.change > 0 ? "more" : "less") than the seven before"
    }
}
