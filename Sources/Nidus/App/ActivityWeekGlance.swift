//
//  ActivityWeekGlance.swift
//  Nidus
//
//  A stacked bar per day, then each category's week against the one before.
//  Drawn in one Canvas, with an entry per day for VoiceOver. It changes only
//  when a saved day does.
//

import SwiftUI

struct ActivityWeekGlance: View {
    let week: ActivityWeek
    var calendar: Calendar = .current

    @State private var hovered: Int?

    private let chartHeight: CGFloat = 96
    private let gap: CGFloat = 8

    var body: some View {
        if week.isEmpty {
            Text("Nothing was counted in these seven days.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                chart
                labels
                Text(verbatim: readout)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
                Divider()
                totals
            }
        }
    }

    private var chart: some View {
        let peak = week.peak
        return GeometryReader { proxy in
            Canvas { context, size in
                let width = (size.width - gap * CGFloat(week.days.count - 1)) / CGFloat(week.days.count)
                for (index, day) in week.days.enumerated() {
                    let x = CGFloat(index) * (width + gap)
                    let track = CGRect(x: x, y: 0, width: width, height: size.height)
                    context.fill(Path(roundedRect: track, cornerRadius: 3, style: .continuous), with: .color(.primary.opacity(0.04)))
                    var bottom = size.height
                    context.drawLayer { layer in
                        layer.clip(to: Path(roundedRect: track, cornerRadius: 3, style: .continuous))
                        for part in day.parts {
                            let height = size.height * part.seconds / peak
                            layer.fill(Path(CGRect(x: x, y: bottom - height, width: width, height: height)),
                                       with: .color(ActivityInk.series(part.tint)))
                            bottom -= height
                        }
                    }
                    if hovered == index {
                        context.stroke(Path(roundedRect: track, cornerRadius: 3, style: .continuous), with: .color(.primary.opacity(0.4)), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(point.x / max(1, proxy.size.width / CGFloat(week.days.count)))
                    hovered = week.days.indices.contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time by day and category")
        .accessibilityChildren {
            ForEach(week.days) { day in
                Rectangle().accessibilityLabel(summary(of: day))
            }
        }
    }

    private var labels: some View {
        HStack(spacing: gap) {
            ForEach(week.days) { day in
                VStack(spacing: 1) {
                    Text(verbatim: name(of: day))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(day.parts.isEmpty ? "\u{2013}" : ActivityDuration.string(day.seconds))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ActivityDuration.string(delta.thisWeek))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if week.hasLastWeek {
                        Text(verbatim: delta.changeText)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description(of: delta))
            }
            if !week.hasLastWeek {
                Text("Nothing to compare with yet: the seven days before are empty.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func name(of day: ActivityWeek.Day) -> String {
        calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day.date) - 1]
    }

    private var readout: String {
        guard let hovered, week.days.indices.contains(hovered) else { return "Hover a day for what filled it." }
        let day = week.days[hovered]
        guard !day.parts.isEmpty else { return "\(day.date.formatted(date: .abbreviated, time: .omitted)) · Nothing counted" }
        return ([day.date.formatted(date: .abbreviated, time: .omitted)] + Self.parts(of: day)).joined(separator: " · ")
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
