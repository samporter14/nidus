//
//  ActivityHeatmap.swift
//  Nidus
//
//  Time by weekday and hour, split into Work, the other categories, which
//  are the ones that distract, and everything else. A finished day never changes, so its grid is
//  worked out once, away from the main actor, and kept.
//

import Foundation

struct ActivityHeatmap: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        var work: TimeInterval = 0
        var distraction: TimeInterval = 0
        var other: TimeInterval = 0
        var total: TimeInterval { work + distraction + other }

        enum Leader { case work, distraction, other }
        /// What filled most of the hour. Named time wins a tie.
        var leader: Leader {
            if other > max(work, distraction) { return .other }
            return work >= distraction ? .work : .distraction
        }
    }

    static let weekdays = 7
    static let hours = 24
    /// `weekdays` rows of `hours`, Sunday first, as `Calendar` numbers them.
    private(set) var cells = [Cell](repeating: Cell(), count: weekdays * hours)

    subscript(weekday weekday: Int, hour hour: Int) -> Cell {
        get { cells[weekday * Self.hours + hour] }
        set { cells[weekday * Self.hours + hour] = newValue }
    }

    var maximum: TimeInterval { cells.map(\.total).max() ?? 0 }
    var isEmpty: Bool { maximum <= 0 }

    init() {}

    /// Each stretch cut at the hours it crosses, so one that runs over
    /// midnight counts on both days, and a clock change repeats or skips an
    /// hour as the calendar does.
    init(stretches: [FocusActivitySegment], categorizer: ActivityCategorizer, calendar: Calendar = .current) {
        var groups: [String: String?] = [:]
        for stretch in stretches where stretch.end > stretch.start {
            let key = stretch.appID + "\u{1}" + (stretch.url ?? stretch.site ?? "")
            let group: String?
            if let known = groups[key] {
                group = known
            } else {
                group = categorizer.category(appID: stretch.appID, site: stretch.site, url: stretch.url)
                groups[key] = .some(group)
            }
            var start = stretch.start
            while start < stretch.end {
                guard let hour = calendar.dateInterval(of: .hour, for: start), hour.end > start else { break }
                let end = min(hour.end, stretch.end)
                let parts = calendar.dateComponents([.weekday, .hour], from: start)
                if let weekday = parts.weekday, let clock = parts.hour {
                    let seconds = end.timeIntervalSince(start)
                    switch group {
                    case ActivityCategorizer.workID: self[weekday: weekday - 1, hour: clock].work += seconds
                    case nil: self[weekday: weekday - 1, hour: clock].other += seconds
                    default: self[weekday: weekday - 1, hour: clock].distraction += seconds
                    }
                }
                start = end
            }
        }
    }

    mutating func add(_ other: ActivityHeatmap) {
        for index in cells.indices {
            cells[index].work += other.cells[index].work
            cells[index].distraction += other.cells[index].distraction
            cells[index].other += other.cells[index].other
        }
    }
}

/// What the grid depends on besides the days. `version` moves when the
/// record is cleared.
struct ActivityDigestSignature: Equatable, Sendable {
    let version: Int
    let excluded: Set<String>
    let work: FocusCategory
    let categories: [FocusCategory]
    let overrides: ActivityOverrides
}

struct ActivityDigestRequest: Equatable, Sendable {
    let signature: ActivityDigestSignature
    /// Moves with each save of today.
    let dayVersion: Int
    let start: Date
    let end: Date
    /// The last day of the week view.
    let weekEnd: Date
}

/// Everything the page draws from one day's file.
struct ActivityDayDigest: Equatable, Sendable {
    var heatmap = ActivityHeatmap()
    /// Seconds by day key, then by group. A stretch that runs past midnight
    /// reaches into the next day's key.
    var byDay: [String: [String: TimeInterval]] = [:]

    init() {}

    init(stretches: [FocusActivitySegment], categorizer: ActivityCategorizer, calendar: Calendar = .current) {
        heatmap = ActivityHeatmap(stretches: stretches, categorizer: categorizer, calendar: calendar)
        for stretch in stretches where stretch.end > stretch.start {
            let group = categorizer.category(appID: stretch.appID, site: stretch.site, url: stretch.url)
                ?? ActivityCategorizer.uncategorizedID
            var start = stretch.start
            while start < stretch.end {
                guard let day = calendar.dateInterval(of: .day, for: start), day.end > start else { break }
                let end = min(day.end, stretch.end)
                byDay[ActivityDayLog.key(for: start, calendar: calendar), default: [:]][group, default: 0] += end.timeIntervalSince(start)
                start = end
            }
        }
    }

    mutating func add(_ other: ActivityDayDigest, grid: Bool) {
        if grid { heatmap.add(other.heatmap) }
        byDay.merge(other.byDay) { $0.merging($1, uniquingKeysWith: +) }
    }
}

actor ActivityDigestCache {
    private var signature: ActivityDigestSignature?
    private var days: [String: ActivityDayDigest] = [:]

    /// `grid` and `week` are the day keys each view covers. `today` is still
    /// being written, so it's never kept: `live` is its latest, and it's
    /// added afresh each time. The rest are loaded only when not already
    /// known; a day with no file is remembered as empty.
    func digest(grid: [String], week: [String], today: String, live: ActivityDayLog?, signature: ActivityDigestSignature,
                categorizer: ActivityCategorizer, calendar: Calendar,
                load: @Sendable ([String]) async -> [ActivityDayLog]) async -> ActivityDayDigest {
        if signature != self.signature {
            self.signature = signature
            days.removeAll()
        }
        let gridDays = Set(grid)
        let wanted = gridDays.union(week)
        let missing = wanted.filter { $0 != today && days[$0] == nil }.sorted()
        if !missing.isEmpty {
            let logs = await load(missing)
            guard signature == self.signature else { return ActivityDayDigest() }
            for key in missing { days[key] = ActivityDayDigest() }
            for log in logs where log.day != today {
                days[log.day] = ActivityDayDigest(stretches: log.stretches, categorizer: categorizer, calendar: calendar)
            }
        }
        var result = ActivityDayDigest()
        for key in wanted where key != today {
            if let day = days[key] { result.add(day, grid: gridDays.contains(key)) }
        }
        if let live, wanted.contains(today) {
            result.add(ActivityDayDigest(stretches: live.stretches, categorizer: categorizer, calendar: calendar),
                       grid: gridDays.contains(today))
        }
        return result
    }

    var cachedDays: Int { days.count }
}
