//
//  ActivityScope.swift
//  Nidus
//
//  What one Activity view covers. A day with a daily record speaks for
//  itself; sessions recorded before all-day tracking, or while it was off,
//  speak for themselves. The same seconds are never counted from both.
//

import AppKit
import Foundation

struct ActivityScope {
    var totals: ActivityTotals
    /// In time order. What the ribbon draws for a single day; empty when
    /// built without the timeline (`includeTimeline: false`).
    var stretches: [FocusActivitySegment]
    /// Whether any stretch went into this scope, timeline kept or not.
    var hasStretches: Bool
    /// Some of this comes from a daily record, so time outside focus is here.
    var hasDailyRecords: Bool
    /// What categories are counted from: the stretches that account for all
    /// of their time, and the rows for time they don't (a session recorded
    /// without a timeline, or a day whose timeline was cut short). Together
    /// they hold each second once.
    private(set) var categoryStretches: [FocusActivitySegment] = []
    private(set) var categoryRows: [(day: Date, row: FocusActivity)] = []

    /// `narrowed`: only time inside these sessions (and `live`, the session
    /// running now) counts, cut to their start and end. `includeTimeline:
    /// false` skips sorting and keeping `stretches`, which only the one-day
    /// ribbon draws; totals, addresses and categories are the same either way.
    init(logs: [ActivityDayLog], sessions: [SessionEntry], narrowed: Bool = false, live: DateInterval? = nil,
         includeTimeline: Bool = true, calendar: Calendar = .current) {
        let days = logs.filter { !$0.isEmpty }
        hasDailyRecords = !days.isEmpty
        var ranges = sessions.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        if let live { ranges.append(live) }
        var rows: [(day: Date, row: FocusActivity)] = []
        var kept: [FocusActivitySegment] = []
        var exact: [FocusActivitySegment] = []
        var unsegmented: [(day: Date, row: FocusActivity)] = []
        for log in days {
            let day = Self.date(of: log.day, calendar: calendar)
            if narrowed {
                let slices = ActivityDayLog.slice(log.stretches, to: ranges)
                kept += slices
                exact += slices
                var slicedDay = ActivityDayLog(day: log.day)
                slices.forEach { slicedDay.add($0) }
                rows += slicedDay.totals.map { (day, $0) }
            } else {
                kept += log.stretches
                rows += log.totals.map { (day, $0) }
                if log.truncated { unsegmented += log.totals.map { (day, $0) } } else { exact += log.stretches }
            }
        }
        let recorded = sessions.isEmpty ? nil : ActivityCoverage(intervals: days.lazy.flatMap(\.recordedIntervals))
        for session in sessions {
            let range = DateInterval(start: session.start, end: max(session.start, session.end))
            if let recorded, recorded.overlaps(range) {
                // Part of this session is in the daily record. Its own timeline
                // shows what isn't. Without one, or on an older day that lost
                // track of what it dropped, adding any of it could count it twice.
                guard let segments = session.activitySegments, session.activityTimelineTruncated != true,
                      !days.contains(where: { !$0.knowsCoverage && Self.day($0.day, calendar: calendar, touches: range) }) else { continue }
                // The two clocks disagree by moments at each edge; that isn't missing time.
                let missing = recorded.uncovered(segments).filter { $0.seconds >= ActivityRecorder.shortestStretch }
                kept += missing
                exact += missing
                rows += missing.map { segment in
                    (calendar.startOfDay(for: segment.start),
                     FocusActivity(appID: segment.appID, appName: segment.appName, site: segment.site, title: segment.title,
                                   seconds: segment.seconds))
                }
                continue
            }
            let day = calendar.startOfDay(for: session.start)
            let own = ActivityTotals.rows(of: session).map { (day, $0) }
            rows += own
            kept += session.activitySegments ?? []
            if let segments = session.activitySegments, !segments.isEmpty, session.activityTimelineTruncated != true {
                exact += segments
            } else {
                unsegmented += own
            }
        }
        categoryStretches = exact.sorted { $0.start < $1.start }
        categoryRows = unsegmented
        hasStretches = !kept.isEmpty
        stretches = includeTimeline ? kept.sorted { $0.start < $1.start } : []
        totals = ActivityTotals(rows: rows, focused: sessions.reduce(0) { $0 + max(0, $1.focused) })
        totals.noteAddresses(from: kept)
    }

    // MARK: Categories

    /// Time per group, longest first. `categorizer` is the groups as they are now.
    func categoryTotals(using categorizer: ActivityCategorizer) -> [ActivityCategoryTotal] {
        categorizer.totals(of: categoryStretches, plus: categoryRows.map(\.row))
    }

    /// The ranked lists for only the time that counts under one group
    /// (`ActivityCategorizer.uncategorizedID` for none). The figures stay
    /// the whole scope's: `focused` is carried over, not cut.
    func totals(in groupID: String, using categorizer: ActivityCategorizer, calendar: Calendar = .current) -> ActivityTotals {
        var seen: [String: String] = [:]
        func group(appID: String, site: String?, url: String?) -> String {
            let key = appID + "\u{1}" + (url ?? site ?? "")
            if let known = seen[key] { return known }
            let id = categorizer.category(appID: appID, site: site, url: url) ?? ActivityCategorizer.uncategorizedID
            seen[key] = id
            return id
        }
        let stretches = categoryStretches.filter { $0.seconds > 0 && group(appID: $0.appID, site: $0.site, url: $0.url) == groupID }
        var rows: [(day: Date, row: FocusActivity)] = stretches.map { stretch in
            (calendar.startOfDay(for: stretch.start),
             FocusActivity(appID: stretch.appID, appName: stretch.appName, site: stretch.site, title: stretch.title,
                           seconds: stretch.seconds))
        }
        rows += categoryRows.filter { group(appID: $0.row.appID, site: $0.row.site, url: nil) == groupID }
        var result = ActivityTotals(rows: rows, focused: totals.focused)
        result.noteAddresses(from: stretches)
        return result
    }

    private static func day(_ key: String, calendar: Calendar, touches range: DateInterval) -> Bool {
        guard let day = calendar.dateInterval(of: .day, for: date(of: key, calendar: calendar)) else { return false }
        return day.end > range.start && day.start < range.end
    }

    private static func date(of key: String, calendar: Calendar) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? .distantPast
    }
}

/// One day drawn to clock scale: blocks for the time in front, and bars for
/// the focus sessions over them. Worked out here, and drawn by the view.
struct ActivityRibbon {
    /// Time a block took from another series, where it happened.
    struct Absorbed: Equatable {
        let start: Date
        var end: Date
        let series: Int
        var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Block: Identifiable, Equatable {
        let id: String
        let start: Date
        let end: Date
        /// Index into `series`, and so a color.
        let series: Int
        /// The site, or the app when there isn't one.
        let name: String
        /// The app behind a site, or the document name.
        let detail: String?
        /// Time counted inside a block merged from several; it can be less
        /// than its span, which runs across small gaps.
        var counted: TimeInterval? = nil
        /// Only a merged block has these: drawn as strips.
        var absorbed: [Absorbed] = []
        /// The same in words, with time.
        var absorbedNote: String? = nil
        var seconds: TimeInterval { counted ?? end.timeIntervalSince(start) }
    }

    struct Focus: Identifiable, Equatable {
        let id: String
        /// nil for the session still running, which has no recap yet.
        let sessionID: UUID?
        let start: Date
        let end: Date
        let name: String
    }

    /// What blocks are colored by.
    enum Coloring {
        case app
        case category(ActivityCategorizer)
    }

    static let otherID = "__other__"
    /// Named in the legend; the rest share a color as Other.
    static let namedSeries = 4

    var span: DateInterval
    var blocks: [Block]
    var focus: [Focus]
    var series: [ActivityRank]
    /// A color for each entry of `series`, and one past the end for Other. A
    /// category keeps its color from day to day, whatever its rank.
    private var tints: [Int] = []
    var isEmpty: Bool { blocks.isEmpty && focus.isEmpty }

    func tint(ofSeries index: Int) -> Int {
        tints.indices.contains(index) ? tints[index] : index
    }

    init(stretches: [FocusActivitySegment], sessions: [SessionEntry], live: Focus? = nil, day: DateInterval, now: Date,
         colorBy: Coloring = .app, calendar: Calendar = .current) {
        // A series is an app, or a group. A page is read once per address.
        var groupOf: [String: String] = [:]
        func seriesKey(of stretch: FocusActivitySegment) -> String {
            guard case .category(let categorizer) = colorBy else { return stretch.appID }
            let address = stretch.appID + "\u{1}" + (stretch.url ?? stretch.site ?? "")
            if let known = groupOf[address] { return known }
            let id = categorizer.category(appID: stretch.appID, site: stretch.site, url: stretch.url) ?? ActivityCategorizer.uncategorizedID
            groupOf[address] = id
            return id
        }
        var seconds: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for stretch in stretches {
            let id = seriesKey(of: stretch)
            seconds[id, default: 0] += stretch.seconds
            if case .category(let categorizer) = colorBy {
                names[id] = categorizer.label(of: id == ActivityCategorizer.uncategorizedID ? nil : id).name
            } else {
                names[id] = stretch.appName
            }
        }
        var ranked: [ActivityRank] = seconds.map { id, value in ActivityRank(id: id, name: names[id] ?? id, seconds: value) }
        ranked.sort { (a: ActivityRank, b: ActivityRank) -> Bool in
            a.seconds == b.seconds ? a.name < b.name : a.seconds > b.seconds
        }
        let named = Array(ranked.prefix(ranked.count > Self.namedSeries + 1 ? Self.namedSeries : Self.namedSeries + 1))
        let rest: TimeInterval = ranked.dropFirst(named.count).map(\.seconds).reduce(0, +)
        series = named + (rest > 0 ? [ActivityRank(id: Self.otherID, name: "Other", seconds: rest)] : [])
        var lookup: [String: Int] = [:]
        for (index, item) in named.enumerated() { lookup[item.id] = index }

        var merged: [FocusActivitySegment] = []
        for stretch in stretches.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, ActivityTimeline.sameContext(last, stretch), stretch.start.timeIntervalSince(last.end) <= 2,
               stretch.start >= last.end {
                merged[merged.count - 1].end = stretch.end
            } else {
                merged.append(stretch)
            }
        }
        blocks = merged.map { stretch in
            if ActivityTimeline.isDocumentService(stretch.site) {
                let name = ActivityTimeline.documentName(title: stretch.title, site: stretch.site) ?? stretch.appName
                return Block(id: stretch.id, start: stretch.start, end: stretch.end, series: lookup[seriesKey(of: stretch)] ?? Self.namedSeries,
                             name: name, detail: [stretch.site, stretch.appName].compactMap { $0 }.joined(separator: " · "))
            }
            let name = stretch.site ?? stretch.title ?? stretch.appName
            let detail = [stretch.site == nil ? nil : stretch.appName, stretch.site == nil ? nil : stretch.title]
                .compactMap { $0 }.joined(separator: " · ")
            return Block(id: stretch.id, start: stretch.start, end: stretch.end, series: lookup[seriesKey(of: stretch)] ?? Self.namedSeries,
                         name: name, detail: detail.isEmpty ? (stretch.title == nil ? nil : stretch.appName) : detail)
        }
        if case .category(let categorizer) = colorBy {
            tints = series.map { $0.id == Self.otherID ? ActivityInk.quietTint : (categorizer.order(of: $0.id) ?? ActivityInk.quietTint) }
            let names = series.map(\.name)
            blocks = ActivityRibbonBands.merged(blocks) { index in names.indices.contains(index) ? names[index] : "Other" }
        }
        focus = sessions.filter { $0.end > $0.start }.sorted { $0.start < $1.start }.map { entry in
            Focus(id: entry.id.uuidString, sessionID: entry.id, start: entry.start, end: entry.end,
                  name: entry.goal.isEmpty ? (entry.projectName ?? "Focus") : entry.goal)
        } + (live.map { [$0] } ?? [])

        // Clock scale, wide enough for a working day and for whatever happened.
        let times = blocks.flatMap { [$0.start, $0.end] } + focus.flatMap { [$0.start, $0.end] }
        let dayStart = calendar.startOfDay(for: day.start)
        let morning = calendar.date(byAdding: .hour, value: 8, to: dayStart) ?? day.start
        let evening = calendar.date(byAdding: .hour, value: 18, to: dayStart) ?? day.end
        var first = min(times.min() ?? morning, morning)
        var last = max(times.max() ?? evening, evening)
        if day.contains(now) { last = max(last, now) }
        first = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        last = calendar.dateInterval(of: .hour, for: last.addingTimeInterval(-1))?.end ?? last
        span = DateInterval(start: max(first, day.start), end: max(min(last, day.end), max(first, day.start).addingTimeInterval(3600)))
    }

    /// Every third hour, and the first hour too when it leaves the next
    /// label room.
    func ticks(calendar: Calendar = .current) -> [Date] {
        var hour = calendar.dateInterval(of: .hour, for: span.start)?.start ?? span.start
        if hour < span.start { hour = hour.addingTimeInterval(3600) }
        let first = hour
        var result: [Date] = []
        while hour <= span.end {
            if calendar.component(.hour, from: hour) % 3 == 0 { result.append(hour) }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        guard let label = result.first else { return [first] }
        return label.timeIntervalSince(first) >= 2 * 3600 ? [first] + result : result
    }

    func position(of date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(span.start) / max(1, span.duration)))
    }

    /// The block under a point along the ribbon, or the nearest within reach
    /// of a narrow one, which may be less than a pixel wide.
    func block(at fraction: Double, reach: Double) -> Block? {
        var best: (block: Block, distance: Double)?
        for block in blocks {
            let start = position(of: block.start), end = position(of: block.end)
            let distance = fraction < start ? start - fraction : (fraction > end ? fraction - end : 0)
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (block, distance) }
        }
        return best?.block
    }
}

/// Where a row in the ranked list goes back to.
enum ActivityReopen: Equatable {
    case page(URL)
    case app(String)

    /// Opens the page, or brings the app forward (launching it if it quit).
    @MainActor
    func perform() {
        switch self {
        case .page(let url):
            NSWorkspace.shared.open(url)
        case .app(let id):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}

extension ActivityRank {
    /// A page's last address, or the app that holds a document.
    var reopenTarget: ActivityReopen? {
        if let kept = ActivityProbe.keptURL(url), let url = URL(string: kept) { return .page(url) }
        return appID.map(ActivityReopen.app)
    }
}
