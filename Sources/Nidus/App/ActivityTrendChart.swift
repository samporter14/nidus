//
//  ActivityTrendChart.swift
//  Nidus
//
//  Each category's time over the kept history as a line: the last month by
//  day, or the last thirteen weeks by week. One Canvas, no Swift Charts.
//  Hovering or arrowing along it reads one bucket in the shared callout.
//  Days the history doesn't reach are shaded, not drawn as zero.
//

import SwiftUI

struct ActivityTrendChart: View {
    let trends: ActivityTrends
    var calendar: Calendar = .current
    @State private var span: ActivityTrend.Span
    @State private var hovered: Int?
    @State private var pointer: CGPoint?
    @State private var keyboardIndex: Int?
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(trends: ActivityTrends, calendar: Calendar = .current, span: ActivityTrend.Span = .month) {
        self.trends = trends
        self.calendar = calendar
        _span = State(initialValue: span)
    }

    static let emptyMessage = "Each category's line fills in as days are kept"
    private let plotHeight: CGFloat = 120
    private let axisHeight: CGFloat = 18
    private let gutter: CGFloat = 34

    private var trend: ActivityTrend { trends[span] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SolanumSegmented(selection: $span, options: ActivityTrend.Span.allCases, label: { Text($0.title) },
                                 accessibilityName: "Trend range")
                Spacer(minLength: 8)
                if let note = trend.shortNote {
                    Text(verbatim: note)
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                chart
                    .activityHoverCallout(callout, at: calloutPoint)
                    .zIndex(callout == nil ? 0 : 1)
                legend
            }
            .chartEmptyState(trend.isEmpty, Self.emptyMessage)
        }
        .onChange(of: span) { hovered = nil; pointer = nil; keyboardIndex = nil }
    }

    // MARK: Callout

    private var activeIndex: Int? {
        if let hovered { return hovered }
        return focused ? keyboardIndex : nil
    }

    private var callout: ActivityCallout? {
        guard let index = activeIndex, trend.buckets.indices.contains(index) else { return nil }
        return Self.callout(of: trend, at: index, calendar: calendar)
    }

    private var calloutPoint: CGPoint? {
        if hovered != nil { return pointer }
        guard focused, let index = keyboardIndex, trend.buckets.indices.contains(index) else { return nil }
        return CGPoint(x: gutter + (CGFloat(index) + 0.5) * step(width: lastWidth), y: 0)
    }

    @State private var lastWidth: CGFloat = 400

    /// "Tue 4 Nov" or "4 Nov", in the calendar's own zone.
    static func format(_ date: Date, weekday: Bool, calendar: Calendar) -> String {
        var style = weekday ? Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
                            : Date.FormatStyle().day().month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func title(of bucket: ActivityTrend.Bucket, span: ActivityTrend.Span, calendar: Calendar) -> String {
        switch span {
        case .month:
            return format(bucket.start, weekday: true, calendar: calendar)
        case .quarter:
            let day = format(bucket.start, weekday: false, calendar: calendar)
            return "Week of \(day)" + (bucket.isPartial ? " (so far)" : "")
        }
    }

    static func callout(of trend: ActivityTrend, at index: Int, calendar: Calendar) -> ActivityCallout {
        let bucket = trend.buckets[index]
        return .ranked(title: title(of: bucket, span: trend.span, calendar: calendar),
                       items: trend.series.map { ($0.id, $0.name, $0.values[index], ActivityInk.series($0.tint)) })
    }

    // MARK: Chart

    private func step(width: CGFloat) -> CGFloat {
        max(1, (width - gutter) / CGFloat(max(1, trend.buckets.count)))
    }

    private func index(at point: CGPoint, width: CGFloat) -> Int? {
        guard point.x >= gutter else { return nil }
        let index = Int((point.x - gutter) / step(width: width))
        return trend.buckets.indices.contains(index) ? index : nil
    }

    private var chart: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Canvas { context, size in draw(&context, size: size) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let hit = index(at: point, width: width)
                        if hit != hovered { hovered = hit }
                        pointer = hit == nil ? nil : point
                    case .ended:
                        if hovered != nil { hovered = nil }
                        pointer = nil
                    }
                }
                .onChange(of: width, initial: true) { _, new in lastWidth = new }
        }
        .frame(height: plotHeight + axisHeight)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused, keyboardIndex == nil { keyboardIndex = trend.buckets.indices.last }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in move(press.key) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time by category over the last \(span == .month ? "month" : "thirteen weeks")")
        .accessibilityValue(focused ? (keyboardIndex.map(spoken(at:)) ?? "") : "")
        .accessibilityHint("Left and right arrow keys move between \(span.bucketName)s")
        .accessibilityChildren {
            ForEach(Array(trend.buckets.enumerated()), id: \.element.id) { offset, _ in
                Rectangle().accessibilityLabel(spoken(at: offset))
            }
        }
    }

    private func move(_ key: KeyEquivalent) -> KeyPress.Result {
        let last = trend.buckets.count - 1
        guard last >= 0 else { return .ignored }
        let current = keyboardIndex ?? last
        switch key {
        case .leftArrow: keyboardIndex = max(0, current - 1)
        case .rightArrow: keyboardIndex = min(last, current + 1)
        case .home: keyboardIndex = 0
        case .end: keyboardIndex = last
        default: return .ignored
        }
        return .handled
    }

    private func spoken(at index: Int) -> String {
        guard trend.buckets.indices.contains(index) else { return "" }
        return Self.callout(of: trend, at: index, calendar: calendar).spoken
    }

    // MARK: Drawing

    /// A round top for the axis: 15 min, 30 min, then whole hours whose
    /// half is also tidy.
    static func niceMax(_ peak: TimeInterval) -> TimeInterval {
        let hours: [TimeInterval] = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 30, 40, 50, 60, 80, 100, 120, 160]
        return hours.map { $0 * 3600 }.first { $0 >= peak } ?? peak
    }

    static func axisLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let trend = trend
        let count = trend.buckets.count
        guard count > 0 else { return }
        let step = step(width: size.width)
        let plot = CGRect(x: gutter, y: 6, width: step * CGFloat(count), height: plotHeight - 6)
        let top = trend.isEmpty ? 4 * 3600 : Self.niceMax(trend.peak)
        func x(_ index: Int) -> CGFloat { plot.minX + (CGFloat(index) + 0.5) * step }
        func y(_ seconds: TimeInterval) -> CGFloat { plot.maxY - plot.height * CGFloat(min(1, seconds / max(1, top))) }

        // Days the history doesn't reach.
        if let first = trend.firstDataIndex, first > 0 {
            let rect = CGRect(x: plot.minX, y: plot.minY, width: step * CGFloat(first), height: plot.height)
            context.fill(Path(roundedRect: rect, cornerRadius: Solanum.markRadius, style: .continuous), with: .color(Solanum.track(contrast)))
        }
        // Gridlines at nothing, half and the top.
        for fraction in [0.0, 0.5, 1.0] {
            let value = top * fraction
            let line = y(value)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: line))
            path.addLine(to: CGPoint(x: plot.maxX, y: line))
            context.stroke(path, with: .color(Solanum.edge(contrast)), lineWidth: 1)
            let label = context.resolve(Text(verbatim: Self.axisLabel(value)).font(.solanum(.caption)).foregroundStyle(Solanum.inkFaint))
            context.draw(label, at: CGPoint(x: gutter - 6, y: line), anchor: .trailing)
        }
        // Dates under the plot, counted back from the newest so it is always named.
        let stride = span == .month ? 7 : 3
        var shownLabel = count - 1
        while shownLabel >= 0 {
            let text = Self.format(trend.buckets[shownLabel].start, weekday: false, calendar: calendar)
            let label = context.resolve(Text(verbatim: text).font(.solanum(.caption)).foregroundStyle(Solanum.inkFaint))
            let anchor: UnitPoint = shownLabel == count - 1 ? .topTrailing : .top
            context.draw(label, at: CGPoint(x: shownLabel == count - 1 ? min(x(shownLabel) + step / 2, size.width) : x(shownLabel),
                                            y: plot.maxY + 4), anchor: anchor)
            shownLabel -= stride
        }
        if let active = activeIndex, trend.buckets.indices.contains(active) {
            let column = CGRect(x: plot.minX + CGFloat(active) * step, y: plot.minY, width: step, height: plot.height)
            let shape = Path(roundedRect: column, cornerRadius: Solanum.markRadius, style: .continuous)
            if hovered == active {
                context.fill(shape, with: .color(Solanum.ink.opacity(0.06)))
            } else {
                context.stroke(shape, with: .color(Solanum.clayText), lineWidth: 2)
            }
        }

        // Lines, from the first day the history holds.
        let start = trend.firstDataIndex ?? 0
        for series in trend.series {
            let color = ActivityInk.series(series.tint).opacity(Solanum.fillOpacity(0.92, contrast))
            let lastIndex = count - 1
            var solid = Path(), dashed = Path()
            for index in start...lastIndex {
                let point = CGPoint(x: x(index), y: y(series.values[index]))
                if index == start { solid.move(to: point) } else if index == lastIndex && trend.buckets[index].isPartial {
                    dashed.move(to: CGPoint(x: x(index - 1), y: y(series.values[index - 1])))
                    dashed.addLine(to: point)
                } else { solid.addLine(to: point) }
            }
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            context.stroke(solid, with: .color(color), style: style)
            context.stroke(dashed, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
            // A single day or week has no line to draw: give it a dot.
            if start == lastIndex {
                context.fill(Path(ellipseIn: CGRect(x: x(start) - 2.5, y: y(series.values[start]) - 2.5, width: 5, height: 5)), with: .color(color))
            }
            if let active = activeIndex, trend.buckets.indices.contains(active), series.values[active] > 0 {
                let dot = CGRect(x: x(active) - 3.5, y: y(series.values[active]) - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(color))
                context.stroke(Path(ellipseIn: dot), with: .color(Solanum.raised), lineWidth: 1.5)
            }
        }
    }

    // MARK: Legend

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            wrappedLegend
        }
        .font(.solanum(.caption))
        .frame(minHeight: 16, alignment: .topLeading)
    }

    private var legendItems: some View {
        ForEach(trend.series) { series in
            ActivityLegend(color: ActivityInk.series(series.tint), title: series.name).fixedSize()
        }
    }

    private var wrappedLegend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(trend.series) { series in
                ActivityLegend(color: ActivityInk.series(series.tint), title: series.name)
            }
        }
    }
}
