//
//  CategoryTarget.swift
//  Nidus
//
//  A daily target for a category ("Work 4 h"): what a saved one may be, the
//  steps Settings offers, and how far a day is towards it. Targets are only
//  ever read by Activity, the popover's Today piece and the Today widget. They
//  never change what a session blocks.
//
//  Pure. The widget does not compile this file; WidgetSnapshot.swift carries
//  its own copy of the few lines of arithmetic it needs, and the tests hold
//  the two together.
//

import Foundation

enum CategoryTarget {
    /// The longest a target can be: a day.
    static let maximum: TimeInterval = 86_400
    /// Settings offers a target in steps of 15 minutes, from 15 m to 12 h.
    static let step: TimeInterval = 900
    static let longestStep: TimeInterval = 43_200

    /// A saved target as long as it is a positive length of time that fits in
    /// a day. Anything else (negative, zero, huge, not a number) is no target.
    static func valid(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds <= maximum else { return nil }
        return seconds
    }

    /// The menu's choices: every step, plus `current` when it is a valid
    /// length that is not on the grid (a target written by hand or by a later
    /// version), so the menu can always show what is saved.
    static func choices(including current: TimeInterval? = nil) -> [TimeInterval] {
        var all = Array(stride(from: step, through: longestStep, by: step))
        if let current = valid(current), !all.contains(current) {
            all.append(current)
            all.sort()
        }
        return all
    }

    /// A time as the words show it: whole minutes, except under one minute,
    /// where it is whole seconds. Met and the fraction compare these, so a
    /// row that reads "4 hr of 4 hr" is never shown as short of its target.
    static func shown(_ seconds: TimeInterval) -> TimeInterval {
        let value = max(0, seconds)
        return value < 60 ? value.rounded() : (value / 60).rounded() * 60
    }

    /// How far `done` is towards `target`, 0 to 1.
    static func fraction(done: TimeInterval, target: TimeInterval) -> Double {
        let goal = shown(target)
        guard goal > 0 else { return 0 }
        return min(1, max(0, shown(done) / goal))
    }

    /// Whether the day has reached its target.
    static func isMet(done: TimeInterval, target: TimeInterval) -> Bool {
        shown(target) > 0 && shown(done) >= shown(target)
    }

    /// The days of `interval` that count towards an average: from its first
    /// day to the last one that has begun by `now`, and at least one. A week
    /// half gone averages over its days so far, not seven.
    static func elapsedDays(in interval: DateInterval, now: Date, calendar: Calendar = .current) -> Int {
        let first = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: min(interval.end.addingTimeInterval(-1), max(now, interval.start)))
        let apart = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return max(1, apart + 1)
    }

    /// The days an average day is worked out over: the days of `interval`,
    /// up to `now`, that have any tracked time. A day with tracking off, or
    /// the Mac away, isn't a day spent short of the target. At least one.
    static func trackedDays(_ tracked: Set<Date>, in interval: DateInterval, now: Date, calendar: Calendar = .current) -> Int {
        let first = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: min(interval.end.addingTimeInterval(-1), max(now, interval.start)))
        let days = Set(tracked.map { calendar.startOfDay(for: $0) }).filter { first <= $0 && $0 <= last }
        return max(1, days.count)
    }
}

/// One targeted category's day (or average day), for the rows in Activity and
/// the popover. A category with a target is listed even when nothing was
/// counted under it, so "0 min of 1 hr" is shown rather than the row
/// vanishing.
struct CategoryTargetProgress: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    /// What its chart colour is (ActivityTint, or a palette slot).
    let tint: Int
    /// Seconds counted: the day's, or the average per day over `days`.
    let done: TimeInterval
    let target: TimeInterval
    /// How many days `done` is an average over; 1 for a single day.
    let days: Int

    var fraction: Double { CategoryTarget.fraction(done: done, target: target) }
    var isMet: Bool { CategoryTarget.isMet(done: done, target: target) }
    var isAverage: Bool { days > 1 }

    /// Every category with a target, Work first and then in the order they are
    /// listed. `totals` are the seconds per group over `days` days.
    static func rows(totals: [ActivityCategoryTotal], categorizer: ActivityCategorizer, days: Int = 1) -> [CategoryTargetProgress] {
        let span = max(1, days)
        return categorizer.targets.map { entry in
            let seconds = totals.first { $0.id == entry.id }?.seconds ?? 0
            let label = categorizer.label(of: entry.id)
            return CategoryTargetProgress(id: entry.id, name: label.name, symbol: label.symbol,
                                          tint: categorizer.tint(of: entry.id), done: seconds / Double(span),
                                          target: entry.target, days: span)
        }
    }

    /// "Work 2 hr 40 min of 4 hr", or "Work 2 hr 40 min a day of 4 hr" for an average.
    var text: String { "\(name) \(Self.amount(self))" }

    /// "2 hr 40 min of 4 hr", or "2 hr 40 min a day of 4 hr" for an average.
    static func amount(_ progress: CategoryTargetProgress) -> String {
        "\(ActivityDuration.string(progress.done))\(progress.isAverage ? " a day" : "") of \(ActivityDuration.string(progress.target))"
    }

    var accessibilityText: String {
        "\(name), \(Self.amount(self)) target\(isMet ? ", met" : "")"
    }
}
