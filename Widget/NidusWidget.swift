//
//  NidusWidget.swift
//  NidusWidget (the widget extension, Contents/PlugIns/NidusWidget.appex)
//
//  The desktop widget (small and medium): the goal and the time left while a
//  session runs, the break while one runs, and the setups to start when
//  nothing does. Nidus Today (small, medium and large): today's Work, distracting
//  and other time, with the day as a ribbon on medium and, on large, focus
//  sessions marked over it and the day's top categories. And two Control Center
//  controls: Start Nidus (the first setup, or the popover when there is none)
//  and End Nidus Session.
//
//  The extension is sandboxed and reads one file, widget.json in Nidus's
//  folder (WidgetSnapshot), through a read-only exception for that folder:
//  no app group, which a self-signed app can't have. Every button is a
//  nidus:// link, so Nidus itself decides, under the same rules as any link:
//  a strict session can't be ended from here.
//
//  SwiftPM doesn't build app extensions; Scripts/build-app.sh compiles this
//  with swiftc beside Core/WidgetSnapshot.swift and App/SolanumTokens.swift.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Reading

enum WidgetFile {
    /// The real home folder: inside the sandbox, NSHomeDirectory() is the
    /// container's.
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Nidus", isDirectory: true)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }
}

struct NidusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NidusProvider: TimelineProvider {
    func placeholder(in context: Context) -> NidusEntry {
        NidusEntry(date: .now, snapshot: WidgetSnapshot(state: .focusing, goal: "Write the launch post",
                                                        endsAt: Date.now.addingTimeInterval(25 * 60).timeIntervalSince1970))
    }

    func getSnapshot(in context: Context, completion: @escaping (NidusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NidusEntry(date: .now, snapshot: WidgetFile.read()))
    }

    /// Nidus reloads the widget at every change; the one change it can't
    /// announce is time running out, so the timeline ends there.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NidusEntry>) -> Void) {
        let snapshot = WidgetFile.read()
        var entries = [NidusEntry(date: .now, snapshot: snapshot)]
        if let end = snapshot.endDate, end > .now {
            var after = snapshot
            after.state = .idle
            after.endsAt = nil
            entries.append(NidusEntry(date: end, snapshot: after))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

// MARK: - The widget

/// Solanum's ink where the widget draws in full colour; the system's styles
/// where a tinted or vibrant desktop needs them to take the accent.
private struct WidgetInk {
    let fullColor: Bool
    let contrast: ColorSchemeContrast

    var primary: Color { fullColor ? Solanum.ink : .primary }
    var muted: Color { fullColor ? Solanum.inkMuted : .secondary }
    var track: Color { fullColor ? Solanum.track(contrast) : Color.primary.opacity(0.12) }
    var edge: Color { fullColor ? Solanum.edge(contrast) : .clear }
    /// Focus: clay, the one accent.
    var focus: Color { fullColor ? Solanum.focus : .primary }
    var tick: Color { fullColor ? Solanum.inkMuted.opacity(0.7) : Color.secondary.opacity(0.7) }

    func kind(_ kind: WidgetToday.Kind) -> Color {
        guard fullColor else {
            // A tinted desktop keeps one color: strength tells them apart.
            switch kind {
            case .work: return .primary
            case .distracting: return .primary.opacity(0.6)
            case .other: return .primary.opacity(0.3)
            }
        }
        switch kind {
        case .work: return Solanum.work
        case .distracting: return Solanum.distracting
        case .other: return Solanum.other
        }
    }

    /// A category's tint as the app draws it: a palette slot, -1 the quiet
    /// "other", -2 the Work group.
    func tint(_ tint: Int) -> Color {
        guard fullColor else { return tint == -1 ? .primary.opacity(0.3) : tint == -2 ? .primary : .primary.opacity(0.6) }
        switch tint {
        case -2: return Solanum.work
        case ..<0: return Solanum.other
        default: return Solanum.series(tint)
        }
    }
}

private struct WidgetBackground: View {
    let fullColor: Bool

    var body: some View {
        if fullColor { Solanum.page } else { Rectangle().fill(.fill.tertiary) }
    }
}

struct NidusWidgetView: View {
    let entry: NidusEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorSchemeContrast) private var contrast

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var ink: WidgetInk { WidgetInk(fullColor: renderingMode == .fullColor, contrast: contrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.solanum(.caption, weight: .semibold))
                .foregroundStyle(snapshot.state == .focusing ? ink.focus : ink.muted)
                .widgetAccentable(snapshot.state == .focusing)
            switch snapshot.state {
            case .idle: idle
            case .focusing, .paused, .onBreak: running
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { WidgetBackground(fullColor: renderingMode == .fullColor) }
        // A small widget is one tap target (links inside it aren't followed):
        // the first setup when idle, else the popover.
        .widgetURL(family == .systemSmall ? smallURL : nil)
    }

    private var smallURL: URL {
        guard snapshot.state == .idle, let first = snapshot.setups.first else { return WidgetSnapshot.popoverURL }
        return WidgetSnapshot.startURL(setupID: first.id)
    }

    private var title: String {
        switch snapshot.state {
        case .idle: return "Nidus"
        case .focusing: return snapshot.strict ? "Focusing · strict" : "Focusing"
        case .paused: return "Paused"
        case .onBreak: return "Break"
        }
    }

    private var symbol: String {
        switch snapshot.state {
        case .idle: return "circle.dashed"
        case .focusing: return snapshot.strict ? "lock.fill" : "brain.head.profile"
        case .paused: return "pause.fill"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }

    @ViewBuilder private var running: some View {
        Text(verbatim: snapshot.goal.isEmpty ? (snapshot.state == .onBreak ? "Next session soon" : "Focus") : snapshot.goal)
            .font(.solanum(.title))
            .foregroundStyle(ink.primary)
            .lineLimit(family == .systemSmall ? 2 : 1)
        Spacer(minLength: 0)
        if let end = snapshot.endDate, snapshot.state != .paused {
            Text(end, style: .timer)
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.medium))
                .foregroundStyle(ink.primary)
            Text("until \(end, style: .time)")
                .font(.solanum(.caption))
                .foregroundStyle(ink.muted)
        } else if let left = snapshot.secondsLeft {
            Text(Duration.seconds(left), format: .time(pattern: .minuteSecond))
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.medium))
                .foregroundStyle(ink.muted)
        } else {
            Text("Open-ended")
                .font(.solanum(.caption))
                .foregroundStyle(ink.muted)
        }
    }

    @ViewBuilder private var idle: some View {
        if snapshot.setups.isEmpty {
            Spacer(minLength: 0)
            Link(destination: WidgetSnapshot.popoverURL) {
                Label("Start a session", systemImage: "play.fill")
                    .font(.solanum(.body, weight: .medium))
                    .foregroundStyle(ink.primary)
            }
        } else {
            // On a small widget only the first is started (the whole widget
            // is its button); the second is shown for what it is.
            let shown = Array(snapshot.setups.prefix(family == .systemSmall ? 2 : WidgetSnapshot.setupLimit))
            Spacer(minLength: 0)
            ForEach(shown) { setup in
                Link(destination: WidgetSnapshot.startURL(setupID: setup.id)) {
                    Label(setup.name, systemImage: setup.symbol)
                        .font(.solanum(.body, weight: .medium))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ink.fullColor ? Solanum.track(contrast) : Color.primary.opacity(0.12),
                                    in: .rect(cornerRadius: Solanum.frameRadius))
                }
            }
        }
    }
}

struct NidusStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.sam.nidus.status", provider: NidusProvider()) { entry in
            NidusWidgetView(entry: entry)
        }
        .configurationDisplayName("Nidus")
        .description("Your goal and time left, or a setup to start.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Nidus Today

struct NidusTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> NidusEntry {
        let bands = [WidgetToday.Band(startMinute: 540, endMinute: 690, kind: .work),
                     WidgetToday.Band(startMinute: 690, endMinute: 720, kind: .distracting),
                     WidgetToday.Band(startMinute: 780, endMinute: 900, kind: .work),
                     WidgetToday.Band(startMinute: 900, endMinute: 960, kind: .other)]
        var today = WidgetToday(day: WidgetToday.key(for: .now), work: 16_200, distracting: 1800, other: 3600, bands: bands)
        today.focus = [.init(startMinute: 555, endMinute: 600), .init(startMinute: 790, endMinute: 850)]
        today.top = [.init(name: "Work", minutes: 270, tint: -2), .init(name: "Writing", minutes: 60, tint: 3),
                     .init(name: "Social", minutes: 30, tint: -1)]
        return NidusEntry(date: .now, snapshot: WidgetSnapshot(today: today))
    }

    func getSnapshot(in context: Context, completion: @escaping (NidusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NidusEntry(date: .now, snapshot: WidgetFile.read()))
    }

    /// Midnight is the one change Nidus can't announce, so the timeline ends
    /// there: the view shows a snapshot only on the day it's about, and the
    /// last entry is the new day.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NidusEntry>) -> Void) {
        let snapshot = WidgetFile.read()
        var entries = [NidusEntry(date: .now, snapshot: snapshot)]
        if let midnight = Calendar.current.dateInterval(of: .day, for: .now)?.end {
            entries.append(NidusEntry(date: midnight, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct NidusTodayView: View {
    let entry: NidusEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorSchemeContrast) private var contrast

    private var ink: WidgetInk { WidgetInk(fullColor: renderingMode == .fullColor, contrast: contrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Today", systemImage: "chart.bar.fill")
                .font(.solanum(.caption, weight: .semibold))
                .foregroundStyle(ink.muted)
            if let today = entry.snapshot.today(at: entry.date) {
                Spacer(minLength: 0)
                switch family {
                case .systemSmall: small(today)
                case .systemLarge: large(today)
                default: medium(today)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { WidgetBackground(fullColor: renderingMode == .fullColor) }
        .widgetURL(WidgetSnapshot.popoverURL)
    }

    // MARK: Empty

    /// The strip as it will look, empty, and one line on what fills it.
    @ViewBuilder private var empty: some View {
        Spacer(minLength: 0)
        Text("Today fills in as you work")
            .font(.solanum(.label))
            .foregroundStyle(ink.muted)
        DayRibbon(parts: [], focus: [], minutes: 1440, height: family == .systemLarge ? 14 : 8,
                  showsHours: family != .systemSmall, ink: ink)
        if family == .systemLarge { Spacer(minLength: 0) }
    }

    // MARK: Layouts

    @ViewBuilder private func small(_ today: WidgetToday) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Work", today.work, .work)
            row("Distracting", today.distracting, .distracting)
            row("Other", today.other, .other)
        }
        Spacer(minLength: 0)
        DayRibbon(parts: shares(today).map { .init(start: $0.start, end: $0.end, color: ink.kind($0.kind), accent: $0.kind == .work) },
                  focus: [], minutes: 1, height: 8, showsHours: false, ink: ink)
    }

    @ViewBuilder private func medium(_ today: WidgetToday) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            column("Work", today.work, .work)
            column("Distracting", today.distracting, .distracting)
            column("Other", today.other, .other)
        }
        Spacer(minLength: 0)
        ribbon(today, height: 8, marksFocus: false)
    }

    @ViewBuilder private func large(_ today: WidgetToday) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            column("Work", today.work, .work)
            column("Distracting", today.distracting, .distracting)
            column("Other", today.other, .other)
        }
        Spacer(minLength: 0)
        ribbon(today, height: 14, marksFocus: true)
        if let top = today.top, !top.isEmpty {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                let biggest = Double(max(1, top.map(\.minutes).max() ?? 1))
                ForEach(Array(top.prefix(WidgetToday.topLimit).enumerated()), id: \.offset) { _, category in
                    categoryRow(category, of: biggest)
                }
            }
        }
        Spacer(minLength: 0)
    }

    private func ribbon(_ today: WidgetToday, height: CGFloat, marksFocus: Bool) -> some View {
        // A clock change makes a day of 25 hours.
        let minutes = Double(max(1440, today.bands.map(\.endMinute).max() ?? 0))
        let parts = today.bands.map {
            DayRibbon.Part(start: Double($0.startMinute) / minutes, end: Double($0.endMinute) / minutes,
                           color: ink.kind($0.kind), accent: $0.kind == .work)
        }
        let focus = marksFocus ? (today.focus ?? []).map { (Double($0.startMinute) / minutes, Double($0.endMinute) / minutes) } : []
        return DayRibbon(parts: parts, focus: focus, minutes: minutes, height: height, showsHours: true, ink: ink)
    }

    // MARK: Pieces

    private func row(_ title: LocalizedStringKey, _ seconds: Int, _ kind: WidgetToday.Kind) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ink.kind(kind)).frame(width: 7, height: 7).widgetAccentable(kind == .work)
            Text(title).font(.solanum(.caption)).foregroundStyle(ink.muted).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: Self.time(seconds)).font(.solanum(.label).monospacedDigit()).foregroundStyle(ink.primary).lineLimit(1)
        }
    }

    private func column(_ title: LocalizedStringKey, _ seconds: Int, _ kind: WidgetToday.Kind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Self.time(seconds)).font(.solanumFigureSmall).foregroundStyle(ink.primary).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(ink.kind(kind)).frame(width: 7, height: 7).widgetAccentable(kind == .work)
                Text(title).font(.solanum(.caption)).foregroundStyle(ink.muted).lineLimit(1)
            }
        }
    }

    /// A category: its swatch, name and time, and a 4 pt bar for how it
    /// compares with the day's biggest.
    private func categoryRow(_ category: WidgetToday.Category, of biggest: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(ink.tint(category.tint)).frame(width: 7, height: 7)
                Text(verbatim: category.name).font(.solanum(.label)).foregroundStyle(ink.primary).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: Self.time(category.minutes * 60))
                    .font(.solanum(.label).monospacedDigit()).foregroundStyle(ink.muted).lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(ink.track)
                    RoundedRectangle(cornerRadius: 2).fill(ink.tint(category.tint))
                        .frame(width: max(2, min(1, Double(category.minutes) / biggest) * proxy.size.width))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
    }

    /// Each part's place along the bar, in the order the rows give them.
    private func shares(_ today: WidgetToday) -> [(start: Double, end: Double, kind: WidgetToday.Kind)] {
        let total = Double(max(1, today.total))
        var start = 0.0
        return [(today.work, WidgetToday.Kind.work), (today.distracting, .distracting), (today.other, .other)].map { seconds, kind in
            defer { start += Double(seconds) / total }
            return (start, start + Double(seconds) / total, kind)
        }
    }

    /// "1h 20m", "45m". Nothing here needs a formatter's weight.
    static func time(_ seconds: Int) -> String {
        let minutes = (seconds + 30) / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// The day as a thin bar with parts along it (0 to 1; at least a point wide,
/// so a short part still shows), optionally with a clay bar of focus above it
/// and 9 AM / 12 PM / 3 PM under it, placed by the same scale as the parts.
private struct DayRibbon: View {
    struct Part {
        var start: Double
        var end: Double
        var color: Color
        var accent: Bool
    }

    /// Hours of the day that are marked, and how they read.
    static let hours: [(hour: Int, label: String)] = [(9, "9 AM"), (12, "12 PM"), (15, "3 PM")]

    let parts: [Part]
    /// Focus sessions, 0 to 1 along the same scale.
    let focus: [(Double, Double)]
    /// The day's length in minutes, which places the hours.
    let minutes: Double
    let height: CGFloat
    let showsHours: Bool
    let ink: WidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !focus.isEmpty {
                GeometryReader { proxy in
                    ForEach(focus.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(ink.focus)
                            .frame(width: max(2, (focus[index].1 - focus[index].0) * proxy.size.width), height: 3)
                            .offset(x: focus[index].0 * proxy.size.width)
                            .widgetAccentable()
                    }
                }
                .frame(height: 3)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(ink.track)
                    ForEach(parts.indices, id: \.self) { index in
                        let part = parts[index]
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(1, (part.end - part.start) * proxy.size.width))
                            .offset(x: part.start * proxy.size.width)
                            .widgetAccentable(part.accent)
                    }
                }
            }
            .frame(height: height)
            .clipShape(.rect(cornerRadius: min(height / 2, Solanum.frameRadius)))
            .overlay(RoundedRectangle(cornerRadius: min(height / 2, Solanum.frameRadius)).strokeBorder(ink.edge, lineWidth: 0.5))
            if showsHours {
                GeometryReader { proxy in
                    ForEach(Self.hours.indices, id: \.self) { index in
                        let x = Double(Self.hours[index].hour * 60) / max(1, minutes) * proxy.size.width
                        Rectangle().fill(ink.tick).frame(width: 1, height: 4).position(x: x, y: 2)
                        Text(Self.hours[index].label)
                            .font(.solanum(.caption))
                            .foregroundStyle(ink.muted)
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: x, y: 12)
                    }
                }
                .frame(height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

struct NidusTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.todayKind, provider: NidusTodayProvider()) { entry in
            NidusTodayView(entry: entry)
        }
        .configurationDisplayName("Nidus Today")
        .description("Today's Work, distracting and other time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Control Center

struct StartNidusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.sam.nidus.start") {
            let first = WidgetFile.read().setups.first
            ControlWidgetButton(action: OpenURLIntent(first.map { WidgetSnapshot.startURL(setupID: $0.id) }
                                                     ?? WidgetSnapshot.popoverURL)) {
                Label(first.map { "Start \($0.name)" } ?? "Start Nidus", systemImage: first?.symbol ?? "play.fill")
            }
        }
        .displayName("Start Nidus")
        .description("Starts your first setup, or opens Nidus when you have none.")
    }
}

struct EndNidusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.sam.nidus.end") {
            ControlWidgetButton(action: OpenURLIntent(WidgetSnapshot.endURL)) {
                Label("End Nidus Session", systemImage: "stop.fill")
            }
        }
        .displayName("End Nidus Session")
        .description("Ends a session that isn't strict.")
    }
}

@main
struct NidusWidgets: WidgetBundle {
    var body: some Widget {
        NidusStatusWidget()
        NidusTodayWidget()
        StartNidusControl()
        EndNidusControl()
    }
}
