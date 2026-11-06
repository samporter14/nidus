//
//  ActivityWeek.swift
//  Nidus
//
//  Seven days by category, against the seven before, from the digests the
//  hour grid keeps. Days are counted on the calendar, so a clock change
//  neither skips nor repeats one.
//

import Foundation

struct ActivityWeek: Equatable, Sendable {
    static let length = 7

    struct Part: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let tint: Int
        let seconds: TimeInterval
    }

    struct Day: Equatable, Sendable, Identifiable {
        let key: String
        let date: Date
        /// Work first, then the categories as listed, Uncategorized last.
        let parts: [Part]
        var id: String { key }
        var seconds: TimeInterval { parts.reduce(0) { $0 + $1.seconds } }
    }

    struct Delta: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let tint: Int
        let thisWeek: TimeInterval
        let lastWeek: TimeInterval
        var change: TimeInterval { thisWeek - lastWeek }

        /// Under a minute either way isn't a change worth reading.
        var changeText: String {
            guard abs(change) >= 60 else { return "Same" }
            return (change > 0 ? "+" : "\u{2212}") + ActivityDuration.string(abs(change))
        }
    }

    /// Oldest first, always `length` of them; a day with nothing has no parts.
    let days: [Day]
    /// Longest this week first. A category with time only last week comes last.
    let deltas: [Delta]
    /// Whether the seven days before hold anything to compare against.
    let hasLastWeek: Bool

    var peak: TimeInterval { days.map(\.seconds).max() ?? 0 }
    var isEmpty: Bool { peak <= 0 }

    /// Two weeks of day keys, oldest first, ending on `last`.
    static func keys(ending last: Date, calendar: Calendar) -> [String] {
        dates(ending: last, count: length * 2, calendar: calendar).map { ActivityDayLog.key(for: $0, calendar: calendar) }
    }

    private static func dates(ending last: Date, count: Int, calendar: Calendar) -> [Date] {
        let end = calendar.startOfDay(for: last)
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
    }

    init(ending last: Date, byDay: [String: [String: TimeInterval]], categorizer: ActivityCategorizer, calendar: Calendar) {
        let name = { (id: String) in categorizer.label(of: id).name }
        let rank = { (id: String) -> Int in categorizer.order(of: id) ?? Int.max }
        let tint = { (id: String) -> Int in categorizer.order(of: id) ?? ActivityInk.quietTint }
        let all = Self.dates(ending: last, count: Self.length * 2, calendar: calendar)
            .map { (date: $0, key: ActivityDayLog.key(for: $0, calendar: calendar)) }
        let earlier = all.prefix(Self.length), shown = all.suffix(Self.length)

        func totals(_ range: some Sequence<(date: Date, key: String)>) -> [String: TimeInterval] {
            var result: [String: TimeInterval] = [:]
            for day in range { result.merge(byDay[day.key] ?? [:], uniquingKeysWith: +) }
            return result
        }

        days = shown.map { day in
            let parts = (byDay[day.key] ?? [:]).filter { $0.value > 0 }
                .sorted { rank($0.key) == rank($1.key) ? $0.key < $1.key : rank($0.key) < rank($1.key) }
                .map { Part(id: $0.key, name: name($0.key), tint: tint($0.key), seconds: $0.value) }
            return Day(key: day.key, date: day.date, parts: parts)
        }
        let now = totals(shown), then = totals(earlier)
        deltas = Set(now.keys).union(then.keys)
            .map { Delta(id: $0, name: name($0), tint: tint($0), thisWeek: now[$0] ?? 0, lastWeek: then[$0] ?? 0) }
            .sorted { a, b in
                if a.thisWeek != b.thisWeek { return a.thisWeek > b.thisWeek }
                if a.lastWeek != b.lastWeek { return a.lastWeek > b.lastWeek }
                return a.name < b.name
            }
        hasLastWeek = then.values.contains { $0 > 0 }
    }
}
