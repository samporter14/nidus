//
//  FocusStatsPage.swift
//  Nidus
//
//  The Stats page in Settings: six months of focus as a grid of
//  days, then the numbers. Worked out from the history file, which stays on
//  this Mac. Each number is said once: the tiles hold this week, the streak
//  and the sessions, and the rows under the graph hold only what they don't.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FocusStatsPage: View {
    @ObservedObject var model: NidusModel
    @State private var confirmingClear = false

    var body: some View {
        let stats = model.stats
        NidusSettingsPage {
            if stats.isEmpty {
                emptyState
            } else {
                summary(stats)
            }
            FocusProjectsSection(model: model)
            history(stats)
        }
        .confirmationDialog("Clear your focus history?", isPresented: $confirmingClear) {
            Button("Clear history", role: .destructive, action: model.clearHistory)
        } message: {
            Text(Self.clearHistoryMessage)
        }
    }

    /// What Clear history says it clears.
    static let clearHistoryMessage = "Every recorded session, the stats worked out from them (each project\u{2019}s time and unfinished goals too), all-day activity, app activity and document names, your recent goals and your resume notes are removed from this Mac. Your projects stay."

    /// With nothing recorded there is nothing to count: the graph's real
    /// frame, faint, and one line saying what fills it. History's own
    /// controls stay below.
    private var emptyState: some View {
        Section {
            graphCard(FocusStats(sessions: []))
                .chartEmptyState(true, model.recordsHistory
                                 ? "Each day you focus fills a square"
                                 : "History is off. Turn it on below to see your sessions here.")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    /// "Last six months" and its graph, on its section's card (as on Activity).
    private func graphCard(_ stats: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            Overline("Last six months")
            ContributionGraph(stats: stats)
        }
        .padding(14)
    }

    @ViewBuilder
    private func summary(_ stats: FocusStats) -> some View {
        Section {
            HStack(spacing: 0) {
                figure("This week", FocusFormat.long(stats.focusedThisWeek))
                Divider()
                figure("Streak", FocusFormat.days(stats.currentStreak))
                Divider()
                figure("Sessions", "\(stats.sessionCount)", caption: "\(stats.completedCount) completed")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        Section {
            graphCard(stats)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }

        NidusSettingsCard {
            NidusControlRow(title: "Time focused") { NidusValuePill(text: FocusFormat.long(stats.totalFocused)) }
            NidusControlRow(title: "Longest streak") { NidusValuePill(text: FocusFormat.days(stats.longestStreak)) }
            NidusControlRow(title: "Longest session") { NidusValuePill(text: longest(stats)) }
            NidusControlRow(title: "Goals finished",
                              infoTip: "From your answers to \u{201C}Did you finish?\u{201D} at the end of a session.") {
                NidusValuePill(text: goals(stats))
            }
        }

        NidusSettingsSection {
            settingsSectionHeader("Distractions")
        } content: {
            NidusSettingsCard {
                NidusControlRow(title: "Most blocked", infoTip: "The app or website stopped most often.") {
                    NidusValuePill(text: tally(stats.mostBlocked))
                }
                NidusControlRow(title: "Most quit", infoTip: "The app Nidus had to quit most often.") {
                    NidusValuePill(text: tally(stats.mostQuit))
                }
            }
        }

        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Where you focused")
                Text("The apps in front while a session ran.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
            }
        } content: {
            Section {
                whereYouFocused(stats)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    /// The apps in front, as the shared ranked bars. Apps are not
    /// categories, so the bars take the neutral ink.
    private func whereYouFocused(_ stats: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if stats.topApps.isEmpty {
                HStack {
                    Text(model.activityTrackingEnabled ? "Nothing yet" : "Activity tracking is off")
                        .font(.solanum(.body, weight: .regular))
                        .foregroundStyle(Solanum.inkMuted)
                    Spacer(minLength: 12)
                    Button("Open Activity") { model.openActivity() }
                }
                .padding(14)
            } else {
                let longest = max(1, stats.topApps.map(\.value).max() ?? 1)
                ForEach(stats.topApps, id: \.key) { app in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(verbatim: app.name)
                                .font(.solanum(.body, weight: .regular))
                                .foregroundStyle(Solanum.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(verbatim: FocusFormat.long(app.value))
                                .font(.solanum(.caption, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Solanum.inkMuted)
                        }
                        SolanumMagnitudeBar(fraction: app.value / longest, color: Solanum.inkMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func history(_ stats: FocusStats) -> some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("History")
                Text("Kept on this Mac only. Nothing is sent anywhere.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
            }
        } content: {
            NidusSettingsCard {
                NidusToggleRow(title: "Record sessions",
                                 subtitle: "Turn this off and finished sessions and goals are no longer kept.",
                                 isOn: model.binding(\.recordsHistory))
                NidusControlRow(title: "Export history",
                                  infoTip: "Saves every session to a file you choose.") {
                    Menu("Export\u{2026}") {
                        Button("Export as CSV\u{2026}") { model.exportHistory(as: .csv) }
                        Button("Export as JSON\u{2026}") { model.exportHistory(as: .json) }
                    }
                    .fixedSize()
                    .disabled(stats.isEmpty)
                }
                NidusControlRow(title: "Clear history",
                                  infoTip: "Also clears your resume notes. Projects stay.") {
                    Button("Clear\u{2026}", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.bordered)
                        // Notes are cleared with the history, and are kept
                        // even when there is no history to clear.
                        .disabled(stats.isEmpty && model.resumeNoteList.isEmpty)
                }
            }
        }
    }

    /// A number, large, under its label, and a line under that when there is
    /// more to say about it.
    private func figure(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Overline(label)
            Text(verbatim: value)
                .font(.solanumFigure)
                .foregroundStyle(Solanum.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(verbatim: caption)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func longest(_ stats: FocusStats) -> String {
        guard let s = stats.longestSession else { return "None yet" }
        return "\(FocusFormat.long(s.focused)), \(s.start.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// "18 of 24, 75%".
    private func goals(_ stats: FocusStats) -> String {
        guard stats.goalsAnswered > 0 else { return "No answers yet" }
        let percent = Int((Double(stats.goalsFinished) / Double(stats.goalsAnswered) * 100).rounded())
        return "\(stats.goalsFinished) of \(stats.goalsAnswered), \(percent)%"
    }

    private func tally(_ t: FocusStats.Tally?) -> String {
        guard let t else { return "Nothing yet" }
        let n = Int(t.value)
        return "\(t.name), \(n) \(n == 1 ? "time" : "times")"
    }
}

// MARK: - Exporting

extension NidusModel {
    /// Asks where to save, as a sheet on Settings, then writes the history
    /// there. The file is built first, so a failure is said before the panel,
    /// not after.
    func exportHistory(as format: HistoryExport.Format) {
        guard let sessions = controller?.history.sessions, !sessions.isEmpty else { return }
        let data: Data
        do {
            switch format {
            case .csv: data = Data(HistoryExport.csv(sessions).utf8)
            case .json: data = try HistoryExport.json(sessions)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Nidus history \(day).\(format.fileExtension)"
        panel.message = format == .csv
            ? "One row per session, for a spreadsheet."
            : "Your sessions as Nidus keeps them."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let write: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = host?.workspace.settings.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}

// MARK: - The graph

/// Six months of days, a column a week, shaded by time focused. The squares
/// grow or shrink to fill the card's width, so the graph ends where the card
/// does and today sits at its right edge.
struct ContributionGraph: View {
    let stats: FocusStats

    private let gap: CGFloat = 3
    private var calendar: Calendar { .current }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            ContributionLayout(columns: stats.weeks.count, gap: gap) {
                // In the order the layout places them: a month over each
                // column, a weekday beside each row, then the days by column.
                let labelled = Self.monthLabelColumns(firstDays: stats.weeks.map { $0.first?.date ?? .distantPast }, calendar: calendar)
                ForEach(0..<stats.weeks.count, id: \.self) { index in
                    Text(verbatim: labelled.contains(index) ? monthName(index) : "")
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
                ForEach(0..<7, id: \.self) { row in
                    // Every other row, starting with the second, as GitHub does:
                    // Mon, Wed, Fri when weeks start on Sunday.
                    Text(verbatim: row % 2 == 1 ? weekday(row) : "")
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                        .lineLimit(1)
                }
                ForEach(Array(stats.weeks.enumerated()), id: \.offset) { _, week in
                    ForEach(week) { day in
                        RoundedRectangle(cornerRadius: Solanum.markRadius, style: .continuous)
                            .fill(day.isFuture ? Color.clear : FocusPalette.graphShade(level: FocusStats.level(for: day.focused), contrast: contrast))
                            .help(day.isFuture ? "" : tooltip(day))
                    }
                }
            }
            HStack(spacing: gap) {
                Spacer(minLength: 0)
                Text("Less").padding(.trailing, 2)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: Solanum.markRadius, style: .continuous)
                        .fill(FocusPalette.graphShade(level: level, contrast: contrast))
                        .frame(width: 12, height: 12)
                }
                Text("More").padding(.leading, 2)
            }
            .font(.solanum(.caption))
            .foregroundStyle(Solanum.inkMuted)
        }
        // One element per week, under a label for the graph as a whole.
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                ForEach(Array(stats.weeks.enumerated()), id: \.offset) { _, week in
                    Text(verbatim: Self.weekSummary(week, calendar: calendar))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spoken)
        }
    }

    /// The columns that carry a month's name: the first column of each month,
    /// and the very first column too unless the next month starts within two
    /// columns of it, where the two names would run together.
    static func monthLabelColumns(firstDays: [Date], calendar: Calendar) -> Set<Int> {
        var starts: [Int] = []
        var previous: Int?
        for (index, date) in firstDays.enumerated() {
            let month = calendar.component(.month, from: date)
            if month != previous { starts.append(index) }
            previous = month
        }
        if starts.count > 1, starts[0] == 0, starts[1] - starts[0] <= 2 { starts.removeFirst() }
        return Set(starts)
    }

    /// "Week of 3 March: 4 hr 10 min over 5 days, best Tuesday 1 hr 20 min",
    /// or "Week of 3 March: no focus". Days still to come are left out.
    static func weekSummary(_ week: [FocusStats.Day], calendar: Calendar, locale: Locale = .current) -> String {
        guard let first = week.first else { return "" }
        let style = { Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone) }
        let start = first.date.formatted(style().day().month(.wide))
        let past = week.filter { !$0.isFuture }
        let active = past.filter { FocusStats.level(for: $0.focused) > 0 }
        guard let best = active.max(by: { $0.focused < $1.focused }) else { return "Week of \(start): no focus" }
        let total = active.reduce(0) { $0 + $1.focused }
        let weekday = best.date.formatted(style().weekday(.wide))
        return "Week of \(start): \(FocusFormat.long(total)) over \(FocusFormat.days(active.count)), best \(weekday) \(FocusFormat.long(best.focused))"
    }

    private var spoken: String {
        let streak = stats.currentStreak > 0 ? "A \(FocusFormat.days(stats.currentStreak)) streak." : "No streak at the moment."
        return "Focus over the last six months. \(FocusFormat.long(stats.focusedThisWeek)) this week. \(streak)"
    }

    private func weekday(_ row: Int) -> String {
        guard let date = stats.weeks.first?[row].date else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func monthName(_ index: Int) -> String {
        guard let first = stats.weeks[index].first?.date else { return "" }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func tooltip(_ day: FocusStats.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return day.focused < 60 ? "\(date): no focus" : "\(date): \(FocusFormat.long(day.focused))"
    }
}

/// Lays the graph out at the width it is given: the squares take whatever is
/// left of it after the weekday labels and the gaps, up to a size past which
/// a wide window would only make a tall graph. Subviews, in order: a month
/// label per column, seven weekday labels, then the days column by column.
private struct ContributionLayout: Layout {
    let columns: Int
    let gap: CGFloat
    private let labelWidth: CGFloat = 32
    private let labelHeight: CGFloat = 13
    private let maxCell: CGFloat = 24

    private func cell(in width: CGFloat) -> CGFloat {
        guard columns > 0 else { return 0 }
        let free = width - labelWidth - gap * CGFloat(columns - 1)
        return max(6, min(maxCell, free / CGFloat(columns)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? labelWidth + CGFloat(columns) * (16 + gap)
        return CGSize(width: width, height: labelHeight + gap + 7 * cell(in: width) + 6 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == columns + 7 + columns * 7 else { return }
        let side = cell(in: bounds.width)
        let left = bounds.minX + labelWidth
        let top = bounds.minY + labelHeight + gap
        for column in 0..<columns {
            // Left-aligned over its column; a name wider than the square
            // runs over the next, which is empty.
            subviews[column].place(at: CGPoint(x: left + CGFloat(column) * (side + gap), y: top - gap),
                                   anchor: .bottomLeading, proposal: .unspecified)
        }
        for row in 0..<7 {
            subviews[columns + row].place(at: CGPoint(x: left - 6, y: top + CGFloat(row) * (side + gap) + side / 2),
                                          anchor: .trailing, proposal: ProposedViewSize(width: labelWidth - 6, height: side))
        }
        for index in 0..<(columns * 7) {
            let column = index / 7, row = index % 7
            subviews[columns + 7 + index].place(
                at: CGPoint(x: left + CGFloat(column) * (side + gap), y: top + CGFloat(row) * (side + gap)),
                anchor: .topLeading, proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

extension FocusFormat {
    /// "3 hr 20 min", "45 min", "0 min".
    static func long(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 0 ? "0 min" : duration(minutes: minutes)
    }

    /// "0 days", "1 day", "5 days".
    static func days(_ n: Int) -> String {
        "\(n) \(n == 1 ? "day" : "days")"
    }
}
