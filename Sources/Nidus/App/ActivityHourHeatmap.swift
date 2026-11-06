//
//  ActivityHourHeatmap.swift
//  Nidus
//
//  Weekdays down, hours across. An hour takes the color of whatever filled
//  most of it, sage for Work and clay for a distracting category, and a
//  stronger color is more time. Drawn in one Canvas, with a row per weekday
//  for VoiceOver. Clicking an hour lists what filled it, read only then.
//

import SwiftUI

struct ActivityHourHeatmap: View {
    let map: ActivityHeatmap
    var calendar: Calendar = .current
    let loadDetail: (ActivityHourSlot) async -> ActivityHourDetail?

    @State private var hovered: ActivityHourSlot?
    @State private var selected: ActivityHourSlot?
    @State private var detail: ActivityHourDetail?

    private let rowHeight: CGFloat = 16
    private let labelWidth: CGFloat = 32
    private let gap: CGFloat = 2

    /// The square's own numbers stand in for its data: the list is read again
    /// only when they move, and a save that touches another hour leaves it.
    private struct DetailKey: Equatable {
        let slot: ActivityHourSlot
        let cell: ActivityHeatmap.Cell
    }

    private var detailKey: DetailKey? {
        selected.map { DetailKey(slot: $0, cell: map[weekday: $0.weekday, hour: $0.hour]) }
    }

    /// The weekdays as this calendar orders them.
    private var weekdays: [Int] {
        (0..<ActivityHeatmap.weekdays).map { ($0 + calendar.firstWeekday - 1) % ActivityHeatmap.weekdays }
    }

    /// The working day, widened to whatever hours hold time.
    private var hours: ClosedRange<Int> {
        var first = 8, last = 18
        for weekday in 0..<ActivityHeatmap.weekdays {
            for hour in 0..<ActivityHeatmap.hours where map[weekday: weekday, hour: hour].total > 0 {
                first = min(first, hour)
                last = max(last, hour)
            }
        }
        return first...last
    }

    var body: some View {
        if map.isEmpty {
            Text("Nothing was counted here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                grid
                axis
                Text(verbatim: readout)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
                HStack(spacing: 13) {
                    ActivityLegend(color: ActivityInk.sage, title: "Work")
                    ActivityLegend(color: ActivityInk.clay, title: "Distracting")
                    ActivityLegend(color: ActivityInk.series(ActivityInk.quietTint), title: "Everything else")
                }
                .font(.system(size: 10))
                if let selected { panel(selected) }
            }
            .task(id: detailKey) { await reloadDetail() }
        }
    }

    /// An hour the shown range no longer holds lets go of its selection.
    private func reloadDetail() async {
        guard let selected else {
            if detail != nil { detail = nil }
            return
        }
        guard map[weekday: selected.weekday, hour: selected.hour].total > 0 else {
            self.selected = nil
            return
        }
        guard let loaded = await loadDetail(selected), !Task.isCancelled, loaded != detail else { return }
        detail = loaded
    }

    private func toggle(_ slot: ActivityHourSlot) {
        guard map[weekday: slot.weekday, hour: slot.hour].total > 0 else { return }
        selected = selected == slot ? nil : slot
    }

    private func panel(_ slot: ActivityHourSlot) -> some View {
        let shown = detail?.slot == slot ? detail : nil
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text(verbatim: name(of: slot))
                    .font(.system(size: 11, weight: .medium))
                Text(ActivityDuration.string(map[weekday: slot.weekday, hour: slot.hour].total))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("Clear") { selected = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let shown {
                HStack(alignment: .top, spacing: 16) {
                    column("Apps", items: shown.apps)
                    if !shown.sites.isEmpty { column("Websites", items: shown.sites) }
                }
            }
        }
        .padding(.top, 3)
    }

    private func column(_ title: String, items: [ActivityHourDetail.Item]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(verbatim: item.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ActivityDuration.string(item.seconds))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), \(ActivityDuration.string(item.seconds))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        let rows = weekdays, columns = Array(hours), peak = map.maximum
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows, id: \.self) { weekday in
                    Text(verbatim: calendar.shortWeekdaySymbols[weekday])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(height: rowHeight)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .accessibilityHidden(true)
            GeometryReader { proxy in
                Canvas { context, size in
                    let width = size.width / CGFloat(columns.count)
                    for (row, weekday) in rows.enumerated() {
                        for (column, hour) in columns.enumerated() {
                            let rect = cellFrame(row: row, column: column, width: width)
                            let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                            context.fill(path, with: .color(.primary.opacity(0.04)))
                            let cell = map[weekday: weekday, hour: hour]
                            guard cell.total > 0 else { continue }
                            context.fill(path, with: .color(color(of: cell).opacity(Self.strength(of: cell, peak: peak))))
                        }
                    }
                    if let hovered, let row = rows.firstIndex(of: hovered.weekday), let column = columns.firstIndex(of: hovered.hour) {
                        let rect = cellFrame(row: row, column: column, width: width)
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous), with: .color(.primary.opacity(0.5)), lineWidth: 1)
                    }
                    if let selected, let row = rows.firstIndex(of: selected.weekday), let column = columns.firstIndex(of: selected.hour) {
                        let rect = cellFrame(row: row, column: column, width: width)
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous), with: .color(.primary), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let slot = slot(at: point, width: proxy.size.width, rows: rows, columns: columns)
                        if slot != hovered { hovered = slot }
                    case .ended:
                        if hovered != nil { hovered = nil }
                    }
                }
                .onTapGesture { point in
                    if let slot = slot(at: point, width: proxy.size.width, rows: rows, columns: columns) { toggle(slot) }
                }
            }
            .frame(height: CGFloat(rows.count) * (rowHeight + gap) - gap)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Time by weekday and hour")
            .accessibilityChildren {
                ForEach(rows, id: \.self) { weekday in
                    rowEntry(weekday)
                }
            }
        }
    }

    /// A weekday's row selects its busiest hour.
    @ViewBuilder
    private func rowEntry(_ weekday: Int) -> some View {
        if let slot = busiest(in: weekday) {
            Rectangle()
                .accessibilityLabel(summary(of: weekday))
                .accessibilityAddTraits(selected == slot ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Lists what filled the busiest hour")
                .accessibilityAction { toggle(slot) }
        } else {
            Rectangle().accessibilityLabel(summary(of: weekday))
        }
    }

    private func slot(at point: CGPoint, width: CGFloat, rows: [Int], columns: [Int]) -> ActivityHourSlot? {
        let column = Int(point.x / max(1, width / CGFloat(columns.count)))
        let row = Int(point.y / (rowHeight + gap))
        guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
        return ActivityHourSlot(weekday: rows[row], hour: columns[column])
    }

    private func cellFrame(row: Int, column: Int, width: CGFloat) -> CGRect {
        CGRect(x: CGFloat(column) * width, y: CGFloat(row) * (rowHeight + gap), width: width - gap, height: rowHeight)
    }

    private var axis: some View {
        let columns = Array(hours)
        return GeometryReader { proxy in
            let width = (proxy.size.width - labelWidth) / CGFloat(columns.count)
            ForEach(columns.filter { $0 % 3 == 0 }, id: \.self) { hour in
                Text(verbatim: Self.hourName(hour, calendar: calendar))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: labelWidth + (CGFloat(hour - columns[0]) + 0.5) * width, y: 6)
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    private func color(of cell: ActivityHeatmap.Cell) -> Color {
        switch cell.leader {
        case .work: ActivityInk.sage
        case .distraction: ActivityInk.clay
        case .other: ActivityInk.series(ActivityInk.quietTint)
        }
    }

    /// Softened, so a quiet hour still shows beside the busiest one.
    static func strength(of cell: ActivityHeatmap.Cell, peak: TimeInterval) -> Double {
        guard peak > 0 else { return 0 }
        return 0.25 + 0.75 * (cell.total / peak).squareRoot()
    }

    static func hourName(_ hour: Int, calendar: Calendar) -> String {
        guard let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour)) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    private var readout: String {
        guard let hovered else { return "Hover an hour for what filled it. Click for its apps and sites." }
        let cell = map[weekday: hovered.weekday, hour: hovered.hour]
        let when = name(of: hovered)
        guard cell.total > 0 else { return "\(when) · Nothing counted" }
        return ([when, ActivityDuration.string(cell.total)] + Self.parts(of: cell)).joined(separator: " · ")
    }

    private func name(of slot: ActivityHourSlot) -> String {
        calendar.weekdaySymbols[slot.weekday] + " " + Self.hourName(slot.hour, calendar: calendar)
    }

    private static func parts(of cell: ActivityHeatmap.Cell) -> [String] {
        [(cell.work, "Work"), (cell.distraction, "distracting"), (cell.other, "other")]
            .filter { $0.0 > 0 }
            .map { "\(ActivityDuration.string($0.0)) \($0.1)" }
    }

    private func busiest(in weekday: Int) -> ActivityHourSlot? {
        var busiest: (hour: Int, seconds: TimeInterval)?
        for hour in 0..<ActivityHeatmap.hours {
            let total = map[weekday: weekday, hour: hour].total
            if total > (busiest?.seconds ?? 0) { busiest = (hour, total) }
        }
        return busiest.map { ActivityHourSlot(weekday: weekday, hour: $0.hour) }
    }

    private func summary(of weekday: Int) -> String {
        var total = ActivityHeatmap.Cell()
        for hour in 0..<ActivityHeatmap.hours {
            let cell = map[weekday: weekday, hour: hour]
            total.work += cell.work
            total.distraction += cell.distraction
            total.other += cell.other
        }
        let name = calendar.weekdaySymbols[weekday]
        guard let busiest = busiest(in: weekday) else { return "\(name), nothing counted" }
        return ([name, ActivityDuration.string(total.total)] + Self.parts(of: total)
            + ["busiest at \(Self.hourName(busiest.hour, calendar: calendar))"]).joined(separator: ", ")
    }
}

/// An open row of the ranked list: an app's sites and files, and a site's
/// pages under it when it's opened in turn.
struct ActivityDrillList: View {
    let appID: String
    let details: [ActivityDrill]
    let open: Set<String>
    let toggle: (String) -> Void

    private static let rowLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(details.prefix(Self.rowLimit)) { item in
                let key = appID + "\u{1F}" + item.id
                row(item, indent: 31, expansion: item.children.isEmpty ? nil : open.contains(key), key: key)
                if open.contains(key) {
                    ForEach(item.children.prefix(Self.rowLimit)) { page in
                        row(page, indent: 47, expansion: nil, key: key + "\u{1F}" + page.id)
                    }
                    more(item.children.count, indent: 47)
                }
            }
            more(details.count, indent: 31)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func row(_ item: ActivityDrill, indent: CGFloat, expansion: Bool?, key: String) -> some View {
        let line = HStack(spacing: 6) {
            Text(verbatim: item.name)
                .font(.system(size: 11))
                .foregroundStyle(item.id == ActivityDrill.unnamedID ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ActivityDuration.string(item.seconds))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let expansion {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expansion ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, indent)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(ActivityDuration.string(item.seconds))")
        if let expansion {
            Button { toggle(key) } label: { line }
                .buttonStyle(.plain)
                .accessibilityValue(expansion ? "Open" : "Closed")
                .accessibilityHint(expansion ? "Hides its pages" : "Shows its pages")
        } else {
            line
        }
    }

    @ViewBuilder
    private func more(_ count: Int, indent: CGFloat) -> some View {
        if count > Self.rowLimit {
            Text("and \(count - Self.rowLimit) more")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, indent)
                .padding(.vertical, 3)
        }
    }
}
