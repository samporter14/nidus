//
//  ActivityDailyBars.swift
//  Nidus
//
//  The week's and month's daily bars: one rounded column per day on a faint
//  track, stacked by app or service in colours that stay put, two gridlines
//  with their hours, and the shared hover callout. Plain SwiftUI shapes, not
//  Swift Charts. Each day is a button that filters the sessions below.
//

import SwiftUI

struct ActivityDailyBars: View {
    /// One stacked part: `id` keys the day's values, `color` never depends
    /// on where the part ranks.
    struct Part: Identifiable, Equatable {
        let id: String
        let name: String
        let color: Color
    }

    let buckets: [Date: [String: TimeInterval]]
    let period: ActivityPeriod
    let anchor: Date
    let calendar: Calendar
    let parts: [Part]
    @Binding var selectedDay: Date?

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hover: (day: Int, point: CGPoint)?

    private static let plotHeight: CGFloat = 85
    private static let gutter: CGFloat = 34
    private static let calloutRows = 5

    struct Day: Identifiable {
        let date: Date
        var values: [String: TimeInterval] = [:]
        var total: TimeInterval { values.values.reduce(0, +) }
        var id: Date { date }
    }

    private var days: [Day] {
        let interval = period.interval(around: anchor, calendar: calendar)
        let count = period == .today ? 1 : (period == .week ? 7 : (calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30))
        let first = calendar.startOfDay(for: interval.start)
        return (0..<count).compactMap { index -> Day? in
            guard let date = calendar.date(byAdding: .day, value: index, to: first) else { return nil }
            return Day(date: date, values: buckets[date] ?? [:])
        }
    }

    private var gap: CGFloat { period == .month ? 2 : 6 }

    var body: some View {
        let days = days
        let ceiling = max(1, days.map(\.total).max() ?? 1)
        VStack(spacing: 7) {
            HStack(alignment: .top, spacing: 4) {
                gridLabels(ceiling: ceiling)
                columns(days, ceiling: ceiling)
            }
            HStack {
                Text("Daily scale")
                Spacer()
                Text("Up to " + ActivityDuration.string(ceiling))
            }
            .font(.solanum(.caption))
            .foregroundStyle(Solanum.inkMuted)
        }
        .zIndex(hover == nil ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily observed activity chart")
    }

    // MARK: Grid

    /// Two gridlines at round times: the largest step that fits twice under
    /// the tallest day, so the lines divide the scale. Empty for a day too
    /// short to split.
    nonisolated static func gridlines(ceiling: TimeInterval) -> [TimeInterval] {
        let steps: [TimeInterval] = [300, 600, 900, 1800, 3600, 7200, 10_800, 14_400, 21_600, 28_800]
        guard let step = steps.last(where: { $0 * 2 <= ceiling }) else { return [] }
        return [step, step * 2]
    }

    private func gridLabels(ceiling: TimeInterval) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Self.gridlines(ceiling: ceiling), id: \.self) { line in
                Text(verbatim: ActivityDuration.string(line))
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: Self.plotHeight * (1 - CGFloat(line / ceiling)) - 7)
            }
        }
        .frame(width: Self.gutter, height: Self.plotHeight, alignment: .topTrailing)
        .accessibilityHidden(true)
    }

    // MARK: Columns

    private func columns(_ days: [Day], ceiling: TimeInterval) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                Canvas { context, size in
                    for line in Self.gridlines(ceiling: ceiling) {
                        let y = size.height * (1 - CGFloat(line / ceiling))
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(Solanum.edge(contrast)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                }
                .allowsHitTesting(false)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(days) { day in
                        column(day, ceiling: ceiling)
                    }
                }
            }
            .frame(height: Self.plotHeight)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = (index(at: point.x, count: days.count), point)
                case .ended: hover = nil
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .activityHoverCallout(hover.flatMap { callout(for: days, at: $0.day) }, at: hover?.point)
            HStack(alignment: .top, spacing: gap) {
                ForEach(days) { day in
                    Text(axisLabel(day.date, count: days.count))
                        .font(.solanum(.caption, weight: .medium))
                        .foregroundStyle(isSelected(day.date) ? Solanum.clayText : Solanum.inkMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @State private var width: CGFloat = 0

    private func index(at x: CGFloat, count: Int) -> Int {
        let column = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard column > 0 else { return 0 }
        return min(count - 1, max(0, Int(x / (column + gap))))
    }

    private func column(_ day: Day, ceiling: TimeInterval) -> some View {
        let selected = isSelected(day.date)
        return Button { selectedDay = day.date } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: Solanum.markRadius, style: .continuous)
                    .fill(Solanum.track(contrast))
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        ForEach(parts) { part in
                            let seconds = day.values[part.id, default: 0]
                            Rectangle()
                                .fill(part.color.opacity(Solanum.fillOpacity(0.88, contrast)))
                                .frame(height: seconds > 0 ? max(1.5, proxy.size.height * CGFloat(seconds / ceiling)) : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: Solanum.markRadius, style: .continuous))
                if selected {
                    RoundedRectangle(cornerRadius: Solanum.markRadius, style: .continuous)
                        .strokeBorder(Solanum.edge(contrast), lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.plotHeight, maxHeight: Self.plotHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func isSelected(_ date: Date) -> Bool {
        selectedDay.map { calendar.isDate($0, inSameDayAs: date) } == true
    }

    private func axisLabel(_ date: Date, count: Int) -> String {
        switch period {
        case .today: return "Today"
        case .week: return date.formatted(.dateTime.weekday(.narrow))
        case .month:
            let day = calendar.component(.day, from: date)
            return day == 1 || day == count || day.isMultiple(of: 5) ? "\(day)" : ""
        }
    }

    // MARK: Words

    private func callout(for days: [Day], at index: Int) -> ActivityCallout? {
        guard days.indices.contains(index) else { return nil }
        let day = days[index]
        let title = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let present = parts.compactMap { part -> (Part, TimeInterval)? in
            let seconds = day.values[part.id, default: 0]
            return seconds > 0 ? (part, seconds) : nil
        }.sorted { $0.1 > $1.1 }
        let rows = present.prefix(Self.calloutRows).map {
            ActivityCallout.Row(id: $0.0.id, name: $0.0.name, value: ActivityDuration.string($0.1), color: $0.0.color)
        }
        let more = present.count - rows.count
        if present.isEmpty {
            return ActivityCallout(title: title, rows: [], footnote: "Nothing counted")
        }
        return ActivityCallout(title: title, rows: Array(rows), footnote: more > 0 ? "\(more) more" : nil)
    }

    private func accessibilityLabel(_ day: Day) -> String {
        let date = day.date.formatted(date: .complete, time: .omitted)
        let detail = parts.compactMap { part -> String? in
            guard let value = day.values[part.id], value > 0 else { return nil }
            return "\(part.name), \(ActivityDuration.string(value))"
        }.joined(separator: "; ")
        return "\(date), \(ActivityDuration.string(day.total)) observed. \(detail). Activate to filter sessions for this day."
    }
}
