//
//  ActivityComparison.swift
//  Nidus
//
//  "40 min more than your usual Tuesday": a day's figure set against the
//  median of the same weekday on the days before it. Pure, so the page only
//  hands it numbers.
//

import Foundation

enum ActivityComparison {
    /// Earlier same-weekday days with data a comparison needs. Fewer say nothing.
    static let minimumDays = 3
    /// How far back the usual weekday is read.
    static let lookbackWeeks = 8
    /// A figure this close to the usual (in seconds) reads as "about".
    static let aboutSeconds: TimeInterval = 600
    /// ... or this close as a share of the usual.
    static let aboutShare = 0.10

    /// The middle value; the mean of the two middle ones for an even count.
    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The starts of the days one, two ... `weeks` weeks before `day`.
    static func sameWeekdayDays(before day: Date, weeks: Int = lookbackWeeks, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: day)
        return (1...max(1, weeks)).compactMap { calendar.date(byAdding: .day, value: -7 * $0, to: start) }
    }

    /// What was counted on the same weekday in the weeks before `day`: not
    /// the day itself, not another weekday, not a later day, and not a day
    /// with nothing counted. `values` is seconds by the start of each day.
    static func history(of day: Date, in values: [Date: TimeInterval], weeks: Int = lookbackWeeks,
                        calendar: Calendar) -> [TimeInterval] {
        sameWeekdayDays(before: day, weeks: weeks, calendar: calendar).compactMap { date in
            values[date].flatMap { $0 > 0 ? $0 : nil }
        }
    }

    enum Verdict: Equatable { case more(TimeInterval), less(TimeInterval), about }

    /// nil with too little history.
    static func verdict(value: TimeInterval, history: [TimeInterval]) -> Verdict? {
        guard history.count >= minimumDays, let usual = median(history) else { return nil }
        let difference = value - usual
        if abs(difference) <= max(aboutSeconds, usual * aboutShare) { return .about }
        return difference > 0 ? .more(difference) : .less(-difference)
    }

    /// The quiet line under a figure. `format` writes a length of time.
    static func phrase(value: TimeInterval, history: [TimeInterval], weekday: String,
                       format: (TimeInterval) -> String) -> String? {
        switch verdict(value: value, history: history) {
        case nil: return nil
        case .about?: return "about your usual \(weekday)"
        case .more(let seconds)?: return "\(format(seconds)) more than your usual \(weekday)"
        case .less(let seconds)?: return "\(format(seconds)) less than your usual \(weekday)"
        }
    }

    /// "Tuesday", in the calendar's own words.
    static func weekdayName(of date: Date, calendar: Calendar) -> String {
        calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }
}

/// The same weekday's earlier figures, for the day on show.
struct ActivityComparisonHistory: Equatable, Sendable {
    /// The day these figures were read for, so a stale set is never shown.
    var day: Date?
    var observed: [TimeInterval] = []
    var focused: [TimeInterval] = []
}
