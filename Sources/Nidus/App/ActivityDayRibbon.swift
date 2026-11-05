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
    /// row that gives way to the hover text, and no legend.
    var compact = false

    @State private var hovered: ActivityRibbon.Block?
    @State private var hoveredFocus: ActivityRibbon.Focus?
    @State private var width: CGFloat = 0

    private var trackHeight: CGFloat { compact ? 16 : 26 }
    /// Hover finds a stretch within this many points, however narrow it is.
    private let hoverReach: CGFloat = 3
    /// Narrower than this, a focus bar has no room for its name.
    private let nameWidth: CGFloat = 58
    private let barHeight: CGFloat = 5

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// One row of 12pt under the track: where the day starts and "now", or
    /// what is under the pointer, so the height never changes on hover.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            focusBars
            track
            ZStack(alignment: .leading) {
                if hovered != nil || hoveredFocus != nil {
                    Text(verbatim: readout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    HStack {
                        Text(verbatim: ribbon.span.start.formatted(date: .omitted, time: .shortened))
                        Spacer(minLength: 0)
                        Text(verbatim: abs(ribbon.span.end.timeIntervalSinceNow) < 600
                             ? "now" : ribbon.span.end.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .leading)
            .clipped()
            .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            focusBars
            track
            axis
            Text(verbatim: readout)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .accessibilityHidden(true)
            legend
        }
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

    private var readout: String {
        if let hoveredFocus {
            let times = hoveredFocus.start.formatted(date: .omitted, time: .shortened) + "–" + hoveredFocus.end.formatted(date: .omitted, time: .shortened)
            return "\(times) · \(hoveredFocus.name)"
        }
        guard let hovered else {
            if ribbon.blocks.isEmpty { return "Nothing was counted on this day." }
            return ribbon.focus.isEmpty ? "Hover a stretch for what was in front." : "Hover a stretch for what was in front. Click a session for its recap."
        }
        return Self.description(of: hovered)
    }

    static func description(of block: ActivityRibbon.Block) -> String {
        let times = block.start.formatted(date: .omitted, time: .shortened) + "–" + block.end.formatted(date: .omitted, time: .shortened)
        return ([times, block.name, block.detail].compactMap { $0 } + [ActivityDuration.string(block.seconds)]).joined(separator: " · ")
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
                                .font(.system(size: 9))
                                .foregroundStyle(ActivityInk.clay)
                                .lineLimit(1)
                        }
                        Capsule().fill(ActivityInk.clay).frame(height: barHeight)
                    }
                    .frame(width: width, height: focusHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bar.sessionID == nil)
                .offset(x: min(x, max(0, proxy.size.width - width)))
                .help(bar.name)
                .onHover { hoveredFocus = $0 ? bar : nil }
                .accessibilityLabel("Focus session, \(bar.name), \(bar.start.formatted(date: .omitted, time: .shortened)) to \(bar.end.formatted(date: .omitted, time: .shortened))")
                .accessibilityHint(bar.sessionID == nil ? "Still running" : "Opens the session recap")
            }
        }
        .frame(height: focusHeight)
    }

    private var track: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6, style: .continuous)
                context.fill(shape, with: .color(.primary.opacity(0.06)))
                context.clip(to: shape)
                for block in ribbon.blocks {
                    let rect = frame(of: block, in: size)
                    context.fill(Path(rect), with: .color(ActivityInk.series(block.series)))
                }
                if let hovered {
                    let rect = frame(of: hovered, in: size)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.18)))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let width = max(1, proxy.size.width)
                    hovered = ribbon.block(at: Double(point.x / width), reach: Double(hoverReach / width))
                case .ended:
                    hovered = nil
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

    private var axis: some View {
        GeometryReader { proxy in
            ForEach(ribbon.ticks(calendar: calendar), id: \.self) { tick in
                let x = proxy.size.width * ribbon.position(of: tick)
                Text(tick.formatted(.dateTime.hour()))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(x, 16), proxy.size.width - 16), y: 6)
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(Array(ribbon.series.enumerated()), id: \.element.id) { index, item in
                ActivityLegend(color: ActivityInk.series(index), title: "\(item.name)  \(ActivityDuration.string(item.seconds))")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10))
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 3)
    }
}
