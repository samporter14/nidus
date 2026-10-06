//
//  WeeklyRecap.swift
//  Nidus
//
//  The week just gone, in a line: Monday's card looks back at the
//  Monday-to-Sunday week before it. Worked out from the history alone, with
//  the calendar and the date passed in, so the tests can pin both. Nothing
//  here schedules anything: the app asks when it launches, wakes or is
//  opened, and this answers.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

struct WeeklyRecap: Equatable, Sendable {
    /// The week's Monday, at midnight.
    var weekStart: Date
    /// Names the week in the settings ("2026-09-21", its Monday), so the
    /// card is shown once per week.
    var weekID: String
    var sessionCount: Int
    var focused: TimeInterval
    /// The day with the most focus; the earlier one when two tie.
    var bestDay: Date?
    /// The weekday's name, in the calendar's own language.
    var bestDayName: String?
    var goalsFinished: Int

    /// The card appears from this hour on Monday, not at midnight: a Mac
    /// that is awake overnight should not drop it on an empty desk.
    static let hour = 9

    // MARK: Text

    /// "Last week: 6 hr 20 min".
    var title: String { "Last week: \(FocusFormat.long(focused))" }

    /// What there is to say, without the parts that are zero.
    var parts: [String] {
        var parts = ["\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"]
        if let bestDayName { parts.append("best day \(bestDayName)") }
        if goalsFinished > 0 { parts.append("\(goalsFinished) \(goalsFinished == 1 ? "goal" : "goals") finished") }
        return parts
    }

    /// "14 sessions · best day Tuesday · 3 goals finished".
    var detail: String { parts.joined(separator: " · ") }

    /// What a screen reader says.
    var spoken: String { "\(title). \(parts.joined(separator: ", "))." }

    // MARK: The week

    /// The Monday on or before `date`, at midnight. Monday to Sunday
    /// whatever the calendar's first weekday: this is a promise made in
    /// words, not a locale's idea of a week.
    static func monday(onOrBefore date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        // weekday: 1 is Sunday, 2 Monday ... 7 Saturday.
        let daysSinceMonday = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    /// When the recap of the week before `monday`'s week becomes due: that
    /// Monday at 9:00 local time.
    static func dueTime(forWeekContaining monday: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: monday) ?? monday
    }

    static func id(forWeekStarting monday: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The recap to show now, or nil. It is due from Monday 9:00 and stays
    /// due the rest of the week until it has been shown, so a Mac that slept
    /// through Monday shows it on Tuesday's wake.
    ///
    /// - `shownWeek` is the `weekID` of the last recap shown.
    /// - `recording` is whether history is being kept: with it off there is
    ///   nothing new to say, and the card would be a reminder of what was
    ///   recorded before.
    /// - `idle` is false during a session or a break: never then.
    static func due(sessions: [SessionEntry], now: Date, shownWeek: String?, recording: Bool = true,
                    idle: Bool = true, calendar: Calendar = .current) -> WeeklyRecap? {
        guard recording, idle else { return nil }
        let thisMonday = monday(onOrBefore: now, calendar: calendar)
        guard now >= dueTime(forWeekContaining: thisMonday, calendar: calendar),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday),
              id(forWeekStarting: lastMonday, calendar: calendar) != shownWeek else { return nil }
        return WeeklyRecap(sessions: sessions, weekStarting: lastMonday, calendar: calendar)
    }

    /// The recap of the week starting `monday`, or nil when it had no
    /// sessions. A session belongs to the week it started in, as it does on
    /// the Stats page's graph.
    init?(sessions: [SessionEntry], weekStarting monday: Date, calendar: Calendar = .current) {
        guard let next = calendar.date(byAdding: .day, value: 7, to: monday) else { return nil }
        let week = sessions.filter { $0.start >= monday && $0.start < next }
        guard !week.isEmpty else { return nil }

        weekStart = monday
        weekID = Self.id(forWeekStarting: monday, calendar: calendar)
        sessionCount = week.count
        focused = week.reduce(0) { $0 + $1.focused }
        goalsFinished = week.filter { $0.finished == true }.count

        var byDay: [Date: TimeInterval] = [:]
        for s in week { byDay[calendar.startOfDay(for: s.start), default: 0] += s.focused }
        bestDay = byDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        bestDayName = bestDay.map { day in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale ?? .current
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: day)
        }
    }
}
