//
//  TodayPopoverPiece.swift
//  Nidus
//
//  The popover's lower half: today at a glance, under the Focus starter. It
//  holds its overview as view state, built when the popover opens and again
//  when the day's record changes, a session starts or ends, or a minute has
//  passed. The clock ticking every second does not touch it. Nothing here
//  outlives the popover: closing it releases the hosting tree.
//

import Combine
import SwiftUI

struct TodayPopoverPiece: View {
    @ObservedObject var model: NidusModel
    @State private var overview: TodayOverview?
    /// Bumped on each rebuild, so the drawn content redraws only then.
    @State private var generation = 0
    @State private var kind: ActivityListKind = .apps

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let overview {
                switch overview.state {
                case .data:
                    TodayContent(overview: overview, generation: generation, kind: $kind, model: model, counted: refresh)
                        .equatable()
                case .empty:
                    note("Nothing counted yet today.")
                case .off:
                    HStack(spacing: NidusSpacing.sm) {
                        note("All-day tracking is off.")
                        Spacer(minLength: 0)
                        Button("Turn on", action: turnOn)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .onReceive(dayVersion) { _ in refresh() }
        .onChange(of: model.isActive) { refresh() }
        .onChange(of: model.isOnBreak) { refresh() }
        // Cancelled by SwiftUI when the popover's tree goes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                refresh()
            }
        }
    }

    /// The day's record changing, as a publisher that is quiet without a controller.
    private var dayVersion: AnyPublisher<Int, Never> {
        guard let controller = model.controller else { return Empty().eraseToAnyPublisher() }
        return controller.$activityDayVersion.dropFirst().eraseToAnyPublisher()
    }

    private func refresh() {
        overview = model.todayOverview()
        generation += 1
    }

    private func turnOn() {
        // Tracking needs the history first; that is its own setting.
        guard model.recordsHistory else { return model.openStats() }
        model.activityTrackingEnabled = true
        model.activityAllDayEnabled = true
        refresh()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Solanum.inkMuted)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: NidusSpacing.sm) {
                Overline("Today")
                if let week = model.botanicalWeek { FocusBotanicalStampRow(week: week) }
                Spacer(minLength: 0)
                Button(action: { model.openActivity() }) {
                    Label("Open Activity", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Solanum.clayText)
                .help("Open Activity in Settings")
            }
            if let overview, overview.state == .data {
                Text(verbatim: Self.totals(overview))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            if let split = overview?.categorySplit, overview?.state == .data {
                CategorySplitLine(split: split)
                    .padding(.leading, 2)
            }
        }
    }

    /// "5h 12m · 1h 40m in focus"; either part is left out when it is zero.
    static func totals(_ overview: TodayOverview) -> String {
        var parts: [String] = []
        if overview.atMac > 0 { parts.append(ActivityDuration.string(overview.atMac)) }
        if overview.focused > 0 { parts.append(ActivityDuration.string(overview.focused) + " in focus") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// "Work 3h 10m · AI 1h 05m · Messaging 40m · Other 12m", on one line. When
/// it does not fit, parts come off the end whole (Other first) rather than a
/// word being cut in half.
private struct CategorySplitLine: View {
    let split: CategorySplit

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(split.parts.count).fixedSize(horizontal: true, vertical: false)
            if split.parts.count > 3 { line(3).fixedSize(horizontal: true, vertical: false) }
            if split.parts.count > 2 { line(2).fixedSize(horizontal: true, vertical: false) }
            line(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(split.text())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(split.text())
    }

    private func line(_ count: Int) -> some View {
        Text(verbatim: split.text(first: count))
            .font(.system(size: 12))
            .foregroundStyle(Solanum.inkMuted)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .semibold))
        }
    }
}

/// The ribbon and the top three. Equatable on `generation` and the chosen
/// list, so the once-a-second redraws of the popover pass it by.
private struct TodayContent: View, Equatable {
    let overview: TodayOverview
    let generation: Int
    @Binding var kind: ActivityListKind
    let model: NidusModel
    /// Rebuilds the overview after a row is counted as something else.
    let counted: () -> Void

    nonisolated static func == (a: TodayContent, b: TodayContent) -> Bool {
        a.generation == b.generation && a.kind == b.kind
    }

    /// Three rows of `rowHeight`, kept as the least height so choosing a
    /// list with fewer rows does not move what is below.
    private static let rowHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityDayRibbon(ribbon: overview.ribbon, openSession: { model.openActivity(sessionID: $0) }, compact: true)
            Picker("List", selection: $kind) {
                ForEach(ActivityListKind.popoverKinds) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Rank today by")
            list
        }
    }

    private var list: some View {
        let rows = overview.rows(kind)
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(Self.emptyNote(kind))
                    .font(.system(size: 12))
                    .foregroundStyle(Solanum.inkMuted)
                    .frame(height: Self.rowHeight, alignment: .leading)
            } else {
                ForEach(rows) { row in
                    TodayRankRow(item: row, maximum: overview.maximum(for: kind), tint: kind.tint,
                                 target: kind == .apps ? row.appID.map(ActivityReopen.app) : row.reopenTarget,
                                 close: { model.menuBarItem?.closePopover() })
                        .frame(height: Self.rowHeight)
                        .activityCountAs(model: model, target: ActivityCountTarget(rank: row, kind: kind), counted: counted)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight * CGFloat(TodayOverview.rowLimit), alignment: .topLeading)
    }

    static func emptyNote(_ kind: ActivityListKind) -> String {
        switch kind {
        case .apps: return "No apps counted yet."
        case .websites: return "No websites counted yet."
        case .documents: return "No documents counted yet."
        case .categories: return "Nothing counted yet."
        }
    }
}

/// A name, its time and a thin share of the longest. A row with somewhere
/// to go reopens it and lets the popover close.
private struct TodayRankRow: View {
    let item: ActivityRank
    let maximum: TimeInterval
    let tint: Color
    let target: ActivityReopen?
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        if let target {
            Button {
                target.perform()
                close()
            } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(item.url == nil && item.appID == nil ? "" : (target.isPage ? "Open again" : "Open the app"))
                .accessibilityHint(target.isPage ? "Opens the page" : "Opens the app")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if target != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Solanum.clayText)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(ActivityDuration.string(item.seconds))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Solanum.inkMuted)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.055))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: max(3, proxy.size.width * min(1, item.seconds / max(1, maximum))))
                    }
            }
            .frame(height: 3)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

private extension ActivityReopen {
    var isPage: Bool { if case .page = self { return true } else { return false } }
}
