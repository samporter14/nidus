//
//  FocusTodayStats.swift
//  Nidus
//
//  Today's focus, for the quiet line at the foot of the idle popover. It
//  lives here, not in FocusHistory.swift, so the Stats page's own changes
//  to FocusStats merge without it.
//

import Foundation

extension FocusStats {
    /// Time focused today, by the `now` and calendar the stats were made
    /// with. It is the last day of the last week that is not in the future,
    /// which is today for any `weeks` of one or more.
    var focusedToday: TimeInterval {
        weeks.last?.last(where: { !$0.isFuture })?.focused ?? 0
    }
}

extension FocusFormat {
    /// "Today 1 hr 10 min · 3-day streak", or nil when there is nothing
    /// worth saying.
    ///
    /// A day with no focus yet says so only while a streak of two days or
    /// more is waiting to be carried on ("No focus yet today · 3-day
    /// streak"): that is the one empty day where the line is a nudge and not
    /// a scoreboard. With no streak, or on a first run, an empty day shows
    /// nothing, so the popover never greets anyone with a zero. A streak of
    /// one is every day's start, so it is not named.
    static func todayLine(focused: TimeInterval, streak: Int) -> String? {
        let streakText = streak >= 2 ? "\(streak)-day streak" : nil
        if focused >= 1 {
            // Never "0 min": under half a minute is a minute.
            let minutes = max(1, Int((focused / 60).rounded()))
            return ["Today \(duration(minutes: minutes))", streakText].compactMap { $0 }.joined(separator: " · ")
        }
        return streakText.map { "No focus yet today · \($0)" }
    }
}
