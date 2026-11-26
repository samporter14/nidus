//
//  ActivityTrend.swift
//  Nidus
//
//  Each category's time over the kept history: a month by day, a quarter by
//  week. Buckets sit on calendar boundaries and are found by stepping the
//  calendar, never by adding 86,400 seconds, so a clock change neither skips
//  nor repeats one. A day the history doesn't hold counts as zero; the model
//  also says how much of the span the history actually reaches.
//

import Foundation

struct ActivityTrend: Equatable, Sendable {
    enum Span: String, CaseIterable, Identifiable, Sendable {
        case month, quarter
        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        /// Buckets in the span: days for a month, weeks for a quarter.
        var count: Int {
            switch self {
            case .month: return 30
            case .quarter: return 13
            }
        }
        var unit: Calendar.Component { self == .month ? .day : .weekOfYear }
        /// What a bucket is called, for "Only 4 weeks kept so far".
        var bucketName: String { self == .month ? "day" : "week" }
    }

    struct Bucket: Equatable, Sendable, Identifiable {
        /// The first moment of the day, or of the week.
        let start: Date
        /// Day keys the bucket covers, none later than the last day shown.
        let keys: [String]
        let seconds: TimeInterval
        /// Whether any time was counted in it.
        let hasData: Bool
        /// A week still going: fewer than seven of its days are shown.
        let isPartial: Bool
        var id: Date { start }
    }

    struct Series: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let tint: Int
        /// One value per bucket, oldest first.
        let values: [TimeInterval]
        var total: TimeInterval { values.reduce(0, +) }
    }

    let span: Span
    /// Oldest first, always `span.count` of them.
    let buckets: [Bucket]
    /// Work first, then the categories as listed, Uncategorized last; only
    /// those with time in the span.
    let series: [Series]

    var isEmpty: Bool { series.isEmpty }
    /// The most any one category reached in one bucket.
    var peak: TimeInterval { series.flatMap(\.values).max() ?? 0 }
    /// Where the history starts: the first bucket with time in it.
    var firstDataIndex: Int? { buckets.firstIndex { $0.hasData } }
    /// Buckets from the first with time to the last. When this is fewer than
    /// the span, the history is shorter than the span.
    var keptCount: Int { firstDataIndex.map { buckets.count - $0 } ?? 0 }
    var isShort: Bool { !isEmpty && keptCount < buckets.count }

    /// "Only 4 weeks kept so far", or nil when the history fills the span.
    var shortNote: String? {
        guard isShort else { return nil }
        return "Only \(keptCount) \(span.bucketName)\(keptCount == 1 ? "" : "s") kept so far"
    }

    // MARK: Buckets

    /// The start of each bucket, oldest first, ending with the one holding `last`.
    static func starts(ending last: Date, span: Span, calendar: Calendar) -> [Date] {
        let day = calendar.startOfDay(for: last)
        let newest: Date
        switch span {
        case .month: newest = day
        case .quarter: newest = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        }
        return (0..<span.count).reversed().compactMap { calendar.date(byAdding: span.unit, value: -$0, to: newest) }
    }

    /// Every day key the span reads, oldest first: what to load.
    static func keys(ending last: Date, span: Span = .quarter, calendar: Calendar) -> [String] {
        guard let first = starts(ending: last, span: span, calendar: calendar).first else { return [] }
        return dayKeys(from: first, through: calendar.startOfDay(for: last), calendar: calendar)
    }

    private static func dayKeys(from first: Date, through last: Date, calendar: Calendar) -> [String] {
        var keys: [String] = []
        var day = first
        while day <= last {
            keys.append(ActivityDayLog.key(for: day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return keys
    }

    init(span: Span, ending last: Date, byDay: [String: [String: TimeInterval]], categorizer: ActivityCategorizer, calendar: Calendar) {
        self.span = span
        let lastDay = calendar.startOfDay(for: last)
        let starts = Self.starts(ending: last, span: span, calendar: calendar)
        let rank = { (id: String) -> Int in categorizer.order(of: id) ?? Int.max }

        var shown: [(start: Date, keys: [String])] = []
        for (index, start) in starts.enumerated() {
            switch span {
            case .month:
                shown.append((start, [ActivityDayLog.key(for: start, calendar: calendar)]))
            case .quarter:
                // The week runs to the next week's start, or to the last day.
                let next = index + 1 < starts.count ? starts[index + 1] : calendar.date(byAdding: .weekOfYear, value: 1, to: start)
                var through = lastDay
                if let next, let before = calendar.date(byAdding: .day, value: -1, to: next) { through = min(before, lastDay) }
                shown.append((start, Self.dayKeys(from: start, through: through, calendar: calendar)))
            }
        }

        var totals: [String: [TimeInterval]] = [:]
        var buckets: [Bucket] = []
        for (index, item) in shown.enumerated() {
            var sum: [String: TimeInterval] = [:]
            for key in item.keys {
                for (id, seconds) in byDay[key] ?? [:] where seconds > 0 { sum[id, default: 0] += seconds }
            }
            for (id, seconds) in sum {
                totals[id, default: Array(repeating: 0, count: starts.count)][index] = seconds
            }
            let seconds = sum.values.reduce(0, +)
            buckets.append(Bucket(start: item.start, keys: item.keys, seconds: seconds, hasData: seconds > 0,
                                  isPartial: span == .quarter && item.keys.count < 7))
        }
        self.buckets = buckets
        series = totals
            .sorted { rank($0.key) == rank($1.key) ? $0.key < $1.key : rank($0.key) < rank($1.key) }
            .map { Series(id: $0.key, name: categorizer.label(of: $0.key).name, tint: categorizer.tint(of: $0.key), values: $0.value) }
    }
}

/// Both spans from one load of the digests, so switching is instant.
struct ActivityTrends: Equatable, Sendable {
    let month: ActivityTrend
    let quarter: ActivityTrend

    init(ending last: Date, byDay: [String: [String: TimeInterval]], categorizer: ActivityCategorizer, calendar: Calendar) {
        month = ActivityTrend(span: .month, ending: last, byDay: byDay, categorizer: categorizer, calendar: calendar)
        quarter = ActivityTrend(span: .quarter, ending: last, byDay: byDay, categorizer: categorizer, calendar: calendar)
    }

    subscript(span: ActivityTrend.Span) -> ActivityTrend { span == .month ? month : quarter }

    /// The day keys both spans read.
    static func keys(ending last: Date, calendar: Calendar) -> [String] {
        ActivityTrend.keys(ending: last, span: .quarter, calendar: calendar)
    }
}
