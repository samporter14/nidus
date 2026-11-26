//
//  ActivityDayRibbon.swift
//  Nidus
//
//  One day to clock scale. Empty track is time nothing was counted: away,
//  idle or asleep. A day can hold hundreds of stretches, so they are drawn
//  in one Canvas, and offered to VoiceOver one by one.
//

import SwiftUI

struct ActivityDayRibbon: View {
    let ribbon: ActivityRibbon
    var calendar: Calendar = .current
    let openSession: (UUID) -> Void
    /// The popover's small ribbon: a thin track, bars without names, one axis
    /// row, and no legend. Hover details come in the shared callout.
    var compact = false

    @State private var hovered: ActivityRibbon.Block?
    @State private var hoveredFocus: ActivityRibbon.Focus?
    @State private var pointer: CGPoint?
    @State private var width: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    private static let space = "ribbon"

    private var trackHeight: CGFloat { compact ? 16 : 26 }
    /// Hover finds a stretch within this many points, however narrow it is.
    private let hoverReach: CGFloat = 3
    /// Narrower than this, a focus bar has no room for its name.
    private let nameWidth: CGFloat = 58
    private let barHeight: CGFloat = 5
    private var stripHeight: CGFloat { compact ? 2 : 3 }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// One row of 12pt under the track: where the day starts and "now".
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            focusBars
            VStack(alignment: .leading, spacing: 4) {
                track
                HStack {
                    Text(verbatim: ribbon.span.start.formatted(date: .omitted, time: .shortened))
                    Spacer(minLength: 0)
                    Text(verbatim: abs(ribbon.span.end.timeIntervalSinceNow) < 600
                         ? "now" : ribbon.span.end.formatted(date: .omitted, time: .shortened))
                }
                .font(.solanum(.caption))
                .foregroundStyle(Solanum.inkMuted)
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .leading)
                .accessibilityHidden(true)
            }
            .chartEmptyState(ribbon.blocks.isEmpty, Self.emptyMessage)
        }
        .coordinateSpace(name: Self.space)
        .activityHoverCallout(callout, at: pointer)
        .zIndex(callout == nil ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    static let emptyMessage = "The timeline appears once something is counted"

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            focusBars
            VStack(alignment: .leading, spacing: 5) {
                track
                axis
            }
            .chartEmptyState(ribbon.blocks.isEmpty, Self.emptyMessage)
            legend
        }
        .coordinateSpace(name: Self.space)
        .activityHoverCallout(callout, at: pointer)
        .zIndex(callout == nil ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func barWidth(_ bar: ActivityRibbon.Focus, in total: CGFloat) -> CGFloat {
        max(6, total * (ribbon.position(of: bar.end) - ribbon.position(of: bar.start)))
    }

    /// Room for names only when one of them fits.
    private var focusHeight: CGFloat {
        if ribbon.focus.isEmpty { return 0 }
        if compact { return barHeight }
        return ribbon.focus.contains { barWidth($0, in: width) >= nameWidth } ? 22 : barHeight
    }

    /// What the pointer is over, for the shared hover callout.
    private var callout: ActivityCallout? {
        if let hoveredFocus {
            return ActivityCallout(
                title: ActivityCallout.timeRange(hoveredFocus.start, hoveredFocus.end, calendar: calendar),
                rows: [.init(id: hoveredFocus.id, name: hoveredFocus.name,
                             value: ActivityDuration.string(hoveredFocus.end.timeIntervalSince(hoveredFocus.start)),
                             color: Solanum.focus)],
                footnote: "Focus session")
        }
        guard let hovered else { return nil }
        return Self.callout(of: hovered, color: ActivityInk.series(ribbon.tint(ofSeries: hovered.series)), calendar: calendar)
    }

    static func callout(of block: ActivityRibbon.Block, color: Color, calendar: Calendar = .current) -> ActivityCallout {
        ActivityCallout(
            title: ActivityCallout.timeRange(block.start, block.end, calendar: calendar),
            rows: [.init(id: block.id, name: block.name, value: ActivityDuration.string(block.seconds), color: color)],
            footnote: [block.detail, block.absorbedNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ").nilIfEmpty)
    }

    static func description(of block: ActivityRibbon.Block) -> String {
        let times = block.start.formatted(date: .omitted, time: .shortened) + "–" + block.end.formatted(date: .omitted, time: .shortened)
        return ([times, block.name, block.detail].compactMap { $0 } + [ActivityDuration.string(block.seconds), block.absorbedNote].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var focusBars: some View {
        GeometryReader { proxy in
            ForEach(ribbon.focus) { bar in
                let x = proxy.size.width * ribbon.position(of: bar.start)
                let width = barWidth(bar, in: proxy.size.width)
                Button {
                    if let id = bar.sessionID { openSession(id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Spacer(minLength: 0)
                        if !compact, width >= nameWidth {
                            Text(verbatim: bar.name)
                                .font(.solanum(.caption))
                                .foregroundStyle(Solanum.clayText)
                                .lineLimit(1)
                        }
                        Capsule().fill(Solanum.focus).frame(height: barHeight)
                    }
                    .frame(width: width, height: focusHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bar.sessionID == nil)
                .offset(x: min(x, max(0, proxy.size.width - width)))
                .help(bar.name)
                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                    switch phase {
                    case .active(let point):
                        hoveredFocus = bar
                        hovered = nil
                        pointer = point
                    case .ended:
                        if hoveredFocus == bar { hoveredFocus = nil; pointer = nil }
                    }
                }
                .accessibilityLabel("Focus session, \(bar.name), \(bar.start.formatted(date: .omitted, time: .shortened)) to \(bar.end.formatted(date: .omitted, time: .shortened))")
                .accessibilityHint(bar.sessionID == nil ? "Still running" : "Opens the session recap")
            }
        }
        .frame(height: focusHeight)
    }

    private var track: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Solanum.frameRadius, style: .continuous)
                context.fill(shape, with: .color(Solanum.track(contrast)))
                context.clip(to: shape)
                for block in ribbon.blocks {
                    let rect = frame(of: block, in: size)
                    context.fill(Path(rect), with: .color(ActivityInk.series(ribbon.tint(ofSeries: block.series))))
                }
                for block in ribbon.blocks {
                    for strip in block.absorbed {
                        let rect = frame(of: strip, in: size)
                        // A hairline over it, so a color shared with the block still shows.
                        context.fill(Path(rect.insetBy(dx: 0, dy: -0.5).offsetBy(dx: 0, dy: -0.5)), with: .color(Solanum.raised))
                        context.fill(Path(rect), with: .color(ActivityInk.series(ribbon.tint(ofSeries: strip.series))))
                    }
                }
                if let hovered {
                    let rect = frame(of: hovered, in: size)
                    context.fill(Path(rect), with: .color(Solanum.ink.opacity(0.18)))
                }
                if contrast == .increased {
                    context.stroke(shape, with: .color(Solanum.edge(contrast)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                switch phase {
                case .active(let point):
                    let width = max(1, proxy.size.width)
                    hoveredFocus = nil
                    hovered = ribbon.block(at: Double(point.x / width), reach: Double(hoverReach / width))
                    pointer = hovered == nil ? nil : point
                case .ended:
                    hovered = nil
                    pointer = nil
                }
            }
        }
        .frame(height: trackHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day timeline")
        .accessibilityChildren {
            ForEach(ribbon.blocks) { block in
                Rectangle().accessibilityLabel(Self.description(of: block))
            }
        }
    }

    private func frame(of block: ActivityRibbon.Block, in size: CGSize) -> CGRect {
        let x = size.width * ribbon.position(of: block.start)
        let end = size.width * ribbon.position(of: block.end)
        return CGRect(x: x, y: 0, width: max(1, end - x), height: size.height)
    }

    private func frame(of strip: ActivityRibbon.Absorbed, in size: CGSize) -> CGRect {
        let x = size.width * ribbon.position(of: strip.start)
        let end = size.width * ribbon.position(of: strip.end)
        return CGRect(x: x, y: size.height - stripHeight, width: max(1, end - x), height: stripHeight)
    }

    private var axis: some View {
        GeometryReader { proxy in
            ForEach(ribbon.ticks(calendar: calendar), id: \.self) { tick in
                let x = proxy.size.width * ribbon.position(of: tick)
                Text(tick.formatted(.dateTime.hour()))
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.inkFaint)
                    .fixedSize()
                    .position(x: min(max(x, 16), proxy.size.width - 16), y: 6)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(Array(ribbon.series.enumerated()), id: \.element.id) { index, item in
                ActivityLegend(color: ActivityInk.series(ribbon.tint(ofSeries: index)), title: "\(item.name)  \(ActivityDuration.string(item.seconds))")
                    .lineLimit(1)
            }
        }
        .font(.solanum(.caption))
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 3)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
