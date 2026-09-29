//
//  FocusStatsPage.swift
//  Nidus
//
//  The Stats page in Settings: six months of focus as a grid of
//  days, then the numbers. Worked out from the history file, which stays on
//  this Mac.
//

import SwiftUI

struct FocusStatsPage: View {
    @ObservedObject var model: NidusModel
    @State private var confirmingClear = false

    var body: some View {
        let stats = model.stats
        DropletSettingsPage {
            HStack(spacing: 0) {
                figure("This week", FocusFormat.long(stats.focusedThisWeek))
                Rectangle().fill(Solanum.hairline).frame(width: 1)
                figure("Streak", FocusFormat.days(stats.currentStreak))
                Rectangle().fill(Solanum.hairline).frame(width: 1)
                figure("Sessions", stats.isEmpty ? "None" : "\(stats.sessionCount)")
            }
            .fixedSize(horizontal: false, vertical: true)
            .solanumCard()

            DropletSettingsCard {
                DropletStackedRow(title: "Last six months") {
                    ContributionGraph(stats: stats)
                        .padding(.vertical, DroppySpacing.xs)
                }
            }

            DropletSettingsCard {
                DropletControlRow(title: "Time focused") { DropletValuePill(text: FocusFormat.long(stats.totalFocused)) }
                DropletControlRow(title: "Sessions") {
                    DropletValuePill(text: stats.isEmpty ? "None yet" : "\(stats.sessionCount), \(stats.completedCount) completed")
                }
                DropletControlRow(title: "Current streak") { DropletValuePill(text: FocusFormat.days(stats.currentStreak)) }
                DropletControlRow(title: "Longest streak") { DropletValuePill(text: FocusFormat.days(stats.longestStreak)) }
                DropletControlRow(title: "Longest session") { DropletValuePill(text: longest(stats)) }
                DropletControlRow(title: "Goals finished",
                                  infoTip: "From your answers to \u{201C}Did you finish?\u{201D} at the end of a session.") {
                    DropletValuePill(text: goals(stats))
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Distractions")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Most blocked", infoTip: "The app or website stopped most often.") {
                        DropletValuePill(text: tally(stats.mostBlocked))
                    }
                    DropletControlRow(title: "Most quit", infoTip: "The app Nidus had to quit most often.") {
                        DropletValuePill(text: tally(stats.mostQuit))
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Where you focused")
                    Text("The apps in front while a session ran.")
                        .font(.system(size: 12))
                        .foregroundStyle(Solanum.inkMuted)
                }
            } content: {
                DropletSettingsCard {
                    if stats.topApps.isEmpty {
                        DropletControlRow(title: "No sessions yet") { EmptyView() }
                    } else {
                        ForEach(stats.topApps, id: \.key) { app in
                            DropletControlRow(title: app.name) { DropletValuePill(text: FocusFormat.long(app.value)) }
                        }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("History")
                    Text("Kept on this Mac only. Nothing is sent anywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(Solanum.inkMuted)
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(title: "Record sessions",
                                     subtitle: "Turn this off and finished sessions and goals are no longer kept.",
                                     isOn: model.binding(\.recordsHistory))
                    DropletControlRow(title: "Clear history") {
                        Button("Clear…", role: .destructive) { confirmingClear = true }
                            .buttonStyle(SolanumButtonStyle())
                            .disabled(stats.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Clear your focus history?", isPresented: $confirmingClear) {
            Button("Clear history", role: .destructive, action: model.clearHistory)
        } message: {
            Text("Every recorded session, the stats worked out from them, and your recent goals are removed from this Mac.")
        }
    }

    /// A number in the serif, under its mono label.
    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Solanum.inkMuted)
            Text(verbatim: value)
                .font(Solanum.serif(28))
                .foregroundStyle(Solanum.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Six months of days, a column a week, shaded by time focused.
struct ContributionGraph: View {
    let stats: FocusStats

    private let cell: CGFloat = 14
    private let gap: CGFloat = 4
    private let labelHeight: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .trailing, spacing: gap) {
                    Color.clear.frame(width: 1, height: labelHeight)
                    ForEach(0..<7, id: \.self) { row in
                        // Every other row, starting with the second, as GitHub does:
                        // Mon, Wed, Fri when weeks start on Sunday.
                        Text(verbatim: row % 2 == 1 ? weekday(row) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(Solanum.inkMuted)
                            .frame(height: cell)
                    }
                }
                .padding(.trailing, 2)
                ForEach(Array(stats.weeks.enumerated()), id: \.offset) { index, week in
                    VStack(alignment: .leading, spacing: gap) {
                        Text(verbatim: month(index))
                            .font(.system(size: 9))
                            .foregroundStyle(Solanum.inkMuted)
                            .fixedSize()
                            .frame(width: cell, height: labelHeight, alignment: .bottomLeading)
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day.isFuture ? Color.clear : FocusPalette.graphShade(level: FocusStats.level(for: day.focused)))
                                .frame(width: cell, height: cell)
                                .help(day.isFuture ? "" : tooltip(day))
                        }
                    }
                }
            }
            HStack(spacing: gap) {
                Text(verbatim: "\(FocusFormat.long(stats.focusedThisWeek)) this week")
                Spacer(minLength: DroppySpacing.md)
                Text("Less").padding(.trailing, 2)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FocusPalette.graphShade(level: level))
                        .frame(width: cell, height: cell)
                }
                Text("More").padding(.leading, 2)
            }
            .font(.system(size: 11))
            .foregroundStyle(Solanum.inkMuted)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus over the last six months. \(FocusFormat.long(stats.focusedThisWeek)) this week, a \(FocusFormat.days(stats.currentStreak)) streak.")
    }

    private func weekday(_ row: Int) -> String {
        guard let date = stats.weeks.first?[row].date else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The month's name above the first column that starts in it.
    private func month(_ index: Int) -> String {
        guard let first = stats.weeks[index].first?.date else { return "" }
        let calendar = Calendar.current
        if index > 0, let previous = stats.weeks[index - 1].first?.date,
           calendar.component(.month, from: previous) == calendar.component(.month, from: first) { return "" }
        if index == 0 { return "" }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func tooltip(_ day: FocusStats.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return day.focused < 60 ? "\(date): no focus" : "\(date): \(FocusFormat.long(day.focused))"
    }
}

extension FocusFormat {
    /// "3 hr 20 min", "45 min", "0 min".
    static func long(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 0 ? "0 min" : duration(minutes: minutes)
    }

    /// "1 day", "5 days", "None".
    static func days(_ n: Int) -> String {
        n == 0 ? "None" : "\(n) \(n == 1 ? "day" : "days")"
    }
}
