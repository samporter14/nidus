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
            Self.forEachHour(of: stretch, calendar: calendar) { slot, seconds in
                switch group {
                case ActivityCategorizer.workID: self[weekday: slot.weekday, hour: slot.hour].work += seconds
                case nil: self[weekday: slot.weekday, hour: slot.hour].other += seconds
                default: self[weekday: slot.weekday, hour: slot.hour].distraction += seconds
                }
            }
        }
    }

    /// A stretch cut at the hours it crosses.
    fileprivate static func forEachHour(of stretch: FocusActivitySegment, calendar: Calendar,
                                        _ body: (ActivityHourSlot, TimeInterval) -> Void) {
        var start = stretch.start
        while start < stretch.end {
            guard let hour = calendar.dateInterval(of: .hour, for: start), hour.end > start else { break }
            let end = min(hour.end, stretch.end)
            let parts = calendar.dateComponents([.weekday, .hour], from: start)
            if let weekday = parts.weekday, let clock = parts.hour {
                body(ActivityHourSlot(weekday: weekday - 1, hour: clock), end.timeIntervalSince(start))
            }
            start = end
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

/// One square of the grid: a weekday, Sunday first, and a clock hour.
struct ActivityHourSlot: Hashable, Sendable {
    let weekday: Int
    let hour: Int
}

/// What filled one square of the grid across a range. Worked out when it's
/// asked for and held only while the square is selected.
struct ActivityHourDetail: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        let name: String
        let seconds: TimeInterval
        var id: String { name }
    }

    static let rowLimit = 5

    let slot: ActivityHourSlot
    private(set) var seconds: TimeInterval = 0
    private var byApp: [String: TimeInterval] = [:]
    private var bySite: [String: TimeInterval] = [:]

    init(slot: ActivityHourSlot) { self.slot = slot }

    /// Cut as the grid cuts, so it adds up to the square.
    mutating func add(_ stretches: [FocusActivitySegment], calendar: Calendar = .current) {
        for stretch in stretches where stretch.end > stretch.start {
            ActivityHeatmap.forEachHour(of: stretch, calendar: calendar) { slot, part in
                guard slot == self.slot else { return }
                seconds += part
                byApp[stretch.appName, default: 0] += part
                if let site = stretch.site { bySite[site, default: 0] += part }
            }
        }
    }

    /// Apps and sites are two views of the same seconds, so they stay apart.
    var apps: [Item] { Self.ranked(byApp) }
    var sites: [Item] { Self.ranked(bySite) }

    private static func ranked(_ values: [String: TimeInterval]) -> [Item] {
        values.map { Item(name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
            .prefix(rowLimit).map { $0 }
    }

    /// The range's days on the slot's weekday, the only files that can hold
    /// it: the recorder cuts a stretch at midnight.
    static func days(of slot: ActivityHourSlot, from start: Date, to end: Date, calendar: Calendar) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            if calendar.component(.weekday, from: day) - 1 == slot.weekday {
                keys.append(ActivityDayLog.key(for: day, calendar: calendar))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
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
    /// Where the shown range starts: the grid looks further back from Today.
    let shownStart: Date
    /// The last day of the week view.
    let weekEnd: Date
}

/// Everything the page draws from one day's file.
struct ActivityDayDigest: Equatable, Sendable {
    var heatmap = ActivityHeatmap()
    /// Seconds by day key, then by group. A stretch that runs past midnight
    /// reaches into the next day's key.
    var byDay: [String: [String: TimeInterval]] = [:]
    /// Drift chains by id, with their count and time.
    var chains: [String: ActivityDriftChain] = [:]

    init() {}

    /// `truncated`: the day dropped its start, so it has no chains to read.
    init(stretches: [FocusActivitySegment], categorizer: ActivityCategorizer, calendar: Calendar = .current, truncated: Bool = false) {
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
        if !truncated {
            ActivityDrift.chains(in: stretches, categorizer: categorizer).forEach { add($0) }
        }
    }

    private mutating func add(_ chain: ActivityDriftChain) {
        if chains[chain.id] == nil { chains[chain.id] = chain } else { chains[chain.id]?.add(chain) }
    }

    mutating func add(_ other: ActivityDayDigest, grid: Bool, drift: Bool) {
        if grid { heatmap.add(other.heatmap) }
        byDay.merge(other.byDay) { $0.merging($1, uniquingKeysWith: +) }
        if drift { other.chains.values.forEach { add($0) } }
    }
}

actor ActivityDigestCache {
    private var signature: ActivityDigestSignature?
    private var days: [String: ActivityDayDigest] = [:]

    /// `grid`, `week` and `chains` are the day keys each view covers. `today` is still
    /// being written, so it's never kept: `live` is its latest, and it's
    /// added afresh each time. The rest are loaded only when not already
    /// known; a day with no file is remembered as empty.
    func digest(grid: [String], week: [String], chains: [String] = [], today: String, live: ActivityDayLog?, signature: ActivityDigestSignature,
                categorizer: ActivityCategorizer, calendar: Calendar,
                load: @Sendable ([String]) async -> [ActivityDayLog]) async -> ActivityDayDigest {
        if signature != self.signature {
            self.signature = signature
            days.removeAll()
            pastHour = nil
        }
        let gridDays = Set(grid)
        let driftDays = Set(chains)
        let wanted = gridDays.union(week).union(driftDays)
        // A day to come isn't finished: remembering it as empty would hide it
        // once it had passed.
        let missing = wanted.filter { $0 < today && days[$0] == nil }.sorted()
        if !missing.isEmpty {
            let logs = await load(missing)
            guard signature == self.signature else { return ActivityDayDigest() }
            for key in missing { days[key] = ActivityDayDigest() }
            for log in logs where log.day != today {
                days[log.day] = ActivityDayDigest(stretches: log.stretches, categorizer: categorizer, calendar: calendar,
                                                  truncated: log.truncated)
            }
        }
        var result = ActivityDayDigest()
        // In date order, so the same days always add up to the same digest.
        for key in wanted.sorted() where key != today {
            if let day = days[key] { result.add(day, grid: gridDays.contains(key), drift: driftDays.contains(key)) }
        }
        if let live, wanted.contains(today) {
            result.add(ActivityDayDigest(stretches: live.stretches, categorizer: categorizer, calendar: calendar,
                                         truncated: live.truncated),
                       grid: gridDays.contains(today), drift: driftDays.contains(today))
        }
        return result
    }

    private var pastHour: (slot: ActivityHourSlot, days: [String], detail: ActivityHourDetail)?

    /// One selected hour across finished days, which won't change, so that a
    /// save only needs today read again.
    func pastHour(_ slot: ActivityHourSlot, days: [String], signature: ActivityDigestSignature,
                  build: @Sendable () async -> ActivityHourDetail) async -> ActivityHourDetail {
        if signature != self.signature {
            self.signature = signature
            self.days.removeAll()
            pastHour = nil
        }
        if let pastHour, pastHour.slot == slot, pastHour.days == days { return pastHour.detail }
        let detail = await build()
        if signature == self.signature { pastHour = (slot, days, detail) }
        return detail
    }

    var cachedDays: Int { days.count }
}
