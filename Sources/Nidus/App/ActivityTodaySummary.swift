//
//  ActivityTodaySummary.swift
//  Nidus
//
//  Today in the three parts the hour grid uses, for the Nidus Today widget and
//  the Shortcuts actions. Each stretch is classified first and the three kinds
//  merged after, so a day reads as a few bands; the seconds are counted from
//  the stretches, so merging never moves them. No ribbon is built for this.
//
//  Pure, and off the main actor at the call. The widget doesn't compile this.
//

import Foundation

enum ActivityTodaySummary {
    private struct Run {
        var start: Date
        var end: Date
        var kind: WidgetToday.Kind
        var seconds: TimeInterval

        mutating func take(_ other: Run) {
            start = min(start, other.start)
            end = max(end, other.end)
            seconds += other.seconds
        }
    }

    /// `sessions` are the focus sessions to mark (any day: only the part inside
    /// today's counts); `now` places the day when the log has no stretch.
    static func build(log: ActivityDayLog, categorizer: ActivityCategorizer, sessions: [SessionEntry] = [],
                      now: Date? = nil, calendar: Calendar = .current) -> WidgetToday {
        var kinds: [String: WidgetToday.Kind] = [:]
        var groups: [String: String?] = [:]
        var groupSeconds: [String?: TimeInterval] = [:]
        var seconds: [WidgetToday.Kind: TimeInterval] = [:]
        var runs: [Run] = []
        runs.reserveCapacity(log.stretches.count)
        for stretch in log.stretches where stretch.end > stretch.start {
            let key = stretch.appID + "\u{1}" + (stretch.url ?? stretch.site ?? "")
            let kind: WidgetToday.Kind
            let id: String?
            if let known = kinds[key], let knownGroup = groups[key] {
                kind = known
                id = knownGroup
            } else {
                // Neutral time folds into "other", so the widget's JSON is unchanged.
                let group = categorizer.category(appID: stretch.appID, site: stretch.site, url: stretch.url)
                id = group
                groups[key] = .some(group)
                switch categorizer.role(forGroup: group) {
                case .work?: kind = .work
                case .distracting?: kind = .distracting
                case .neutral?, nil: kind = .other
                }
                kinds[key] = kind
            }
            seconds[kind, default: 0] += stretch.seconds
            groupSeconds[id, default: 0] += stretch.seconds
            runs.append(Run(start: stretch.start, end: stretch.end, kind: kind, seconds: stretch.seconds))
        }
        func whole(_ kind: WidgetToday.Kind) -> Int { Int((seconds[kind] ?? 0).rounded()) }
        var today = WidgetToday(day: log.day, work: whole(.work), distracting: whole(.distracting), other: whole(.other))
        let dayInterval = (runs.first?.start ?? now).flatMap { calendar.dateInterval(of: .day, for: $0) }
        if let dayInterval, !runs.isEmpty { today.bands = bands(runs, in: dayInterval) }
        if let dayInterval {
            today.focus = focusSpans(sessions, in: dayInterval)
            today.top = top(groupSeconds, categorizer: categorizer)
        }
        return today
    }

    // MARK: Focus and categories

    /// Focus sessions' time inside the day, joined where they touch, in minutes.
    static func focusSpans(_ sessions: [SessionEntry], in day: DateInterval) -> [WidgetToday.Span] {
        let inside = sessions.compactMap { entry -> (Double, Double)? in
            let start = max(0, entry.start.timeIntervalSince(day.start))
            let end = min(day.duration, entry.end.timeIntervalSince(day.start))
            return end > start ? (start / 60, end / 60) : nil
        }.sorted { $0.0 < $1.0 }
        var joined: [(Double, Double)] = []
        for span in inside {
            if let last = joined.last, span.0 <= last.1 {
                joined[joined.count - 1].1 = max(last.1, span.1)
            } else {
                joined.append(span)
            }
        }
        return joined.suffix(WidgetToday.spanLimit).map {
            WidgetToday.Span(startMinute: Int($0.0), endMinute: max(Int($0.0) + 1, Int($0.1.rounded(.up))))
        }
    }

    /// The biggest categories by time, biggest first (ties by name), under
    /// the names and tints the app's charts use. A category that rounds to no
    /// minutes isn't listed.
    static func top(_ seconds: [String?: TimeInterval], categorizer: ActivityCategorizer) -> [WidgetToday.Category] {
        let all = seconds.compactMap { id, time -> (WidgetToday.Category, TimeInterval)? in
            let minutes = Int((time / 60).rounded())
            guard minutes > 0 else { return nil }
            return (WidgetToday.Category(name: categorizer.label(of: id).name, minutes: minutes,
                                         tint: categorizer.tint(of: id)), time)
        }
        return all.sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
            .prefix(WidgetToday.topLimit).map(\.0)
    }

    // MARK: Bands

    /// As the day's ribbon joins and absorbs, then down to the limit, shortest
    /// first. One with no neighbor in reach falls off the drawing; its time
    /// is still in the totals.
    private static func bands(_ runs: [Run], in day: DateInterval) -> [WidgetToday.Band] {
        var merged = joined(runs.sorted { $0.start < $1.start })
        for step in ActivityRibbonBands.steps where merged.count > WidgetToday.bandLimit {
            merged = joined(absorbing(merged, shorterThan: step))
        }
        while merged.count > WidgetToday.bandLimit, let shortest = merged.map(\.seconds).min() {
            let absorbed = joined(absorbing(merged, shorterThan: shortest.nextUp))
            if absorbed.count < merged.count {
                merged = absorbed
            } else if let alone = merged.firstIndex(where: { $0.seconds == shortest }) {
                merged.remove(at: alone)
            }
        }
        return merged.compactMap { run in
            let start = max(0, run.start.timeIntervalSince(day.start))
            let end = min(day.duration, run.end.timeIntervalSince(day.start))
            guard end > start else { return nil }
            return WidgetToday.Band(startMinute: Int(start / 60), endMinute: Int((end / 60).rounded(.up)), kind: run.kind)
        }
    }

    private static func joined(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs {
            if let last = result.last, last.kind == run.kind,
               run.start.timeIntervalSince(last.end) <= ActivityRibbonBands.bridge {
                result[result.count - 1].take(run)
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// A short run goes into the longer neighbor within reach, which keeps
    /// its kind. One with neither stands alone.
    private static func absorbing(_ runs: [Run], shorterThan limit: TimeInterval) -> [Run] {
        var result: [Run] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            let previous = result.last.flatMap { run.start.timeIntervalSince($0.end) <= ActivityRibbonBands.bridge ? $0 : nil }
            let next = index + 1 < runs.count && runs[index + 1].start.timeIntervalSince(run.end) <= ActivityRibbonBands.bridge
                ? runs[index + 1] : nil
            guard run.seconds < limit, previous != nil || next != nil else {
                result.append(run)
                index += 1
                continue
            }
            if let previous, previous.seconds >= next?.seconds ?? 0 {
                result[result.count - 1].take(run)
                index += 1
            } else if var next {
                next.take(run)
                result.append(next)
                index += 2
            }
        }
        return result
    }

    // MARK: Said aloud

    static func workMinutes(_ today: WidgetToday) -> Int { minutes(today.work) }

    private static func minutes(_ seconds: Int) -> Int { Int((Double(seconds) / 60).rounded()) }

    static func sentence(_ today: WidgetToday, tracking: Bool) -> String {
        guard today.total > 0 else {
            return tracking ? "Nidus hasn't counted anything today." : offSentence
        }
        var parts: [String] = []
        if minutes(today.work) > 0 { parts.append("\(FocusFormat.minutes(minutes(today.work))) of Work") }
        if minutes(today.distracting) > 0 { parts.append("\(FocusFormat.minutes(minutes(today.distracting))) distracting") }
        if minutes(today.other) > 0 { parts.append("\(FocusFormat.minutes(minutes(today.other))) of everything else") }
        guard !parts.isEmpty else { return "Under a minute counted today." }
        return "Today so far: \(parts.joined(separator: ", "))."
    }

    /// `workHasItems` tells a Work group nothing can count in from a day with
    /// no Work in it yet.
    static func workSentence(_ today: WidgetToday, tracking: Bool, workHasItems: Bool) -> String {
        if today.work > 0 {
            let shown = workMinutes(today)
            return shown > 0 ? "\(FocusFormat.minutes(shown)) of Work today." : "Under a minute of Work today."
        }
        if !workHasItems { return "Your Work group is empty, so nothing counts as Work. Add apps or websites to it in Nidus." }
        return tracking ? "No Work time yet today." : offSentence
    }

    private static let offSentence = "All-day Activity is off in Nidus, so it has nothing for today."
}

/// When the widget's summary may be worked out again. A save lands about every
/// two minutes; the file is written at most every 15, or at a new day, and at
/// once when what it may show changed: a cleared record, an excluded app.
struct WidgetTodayThrottle: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        /// Moves when the record is cleared.
        var version: Int
        var excluded: Set<String>
    }

    static let interval: TimeInterval = 15 * 60

    /// The last one worked out from, written or not.
    var source: Source?
    private(set) var lastDay: String?
    private(set) var lastWrite: Date?

    func isDue(day: String, source: Source, now: Date) -> Bool {
        guard let lastWrite, day == lastDay, source == self.source else { return true }
        let elapsed = now.timeIntervalSince(lastWrite)
        // A clock set back must not hold the next write off.
        return elapsed >= Self.interval || elapsed < 0
    }

    mutating func didWrite(day: String, at date: Date) {
        lastDay = day
        lastWrite = date
    }
}
