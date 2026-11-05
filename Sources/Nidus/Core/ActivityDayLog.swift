//
//  ActivityDayLog.swift
//  Nidus
//
//  One day of all-day activity, the content of one file: totals, and the
//  ordered stretches behind them: apps, service labels, domains, titles, and
//  on each stretch the page's address. Websites are counted by domain.
//

import Foundation

extension ActivityTimeline {
    /// A site label: a service, or a bare domain. An address is kept apart,
    /// in a stretch's `url`, so websites group by domain.
    static func safeDaySite(_ site: String?) -> String? {
        guard let site else { return nil }
        return safeSite(site) ?? (ActivityDomain.isDomain(site) ? site : nil)
    }
}

struct ActivityDayLog: Codable, Equatable, Sendable {
    /// Four stretches a minute is an ordinary busy day, so this holds a full
    /// 24 hours at that pace with room to spare. It is a wall, not a target.
    static let stretchLimit = 8192
    /// Past this many rows, names stop adding rows but the time still counts.
    static let totalsLimit = 1024

    var version = 1
    /// `YYYY-MM-DD`, the day in the calendar it was recorded in.
    var day: String
    /// Complete even when `stretches` has dropped its start.
    var totals: [FocusActivity] = []
    var stretches: [FocusActivitySegment] = []
    var truncated = false
    /// When the time dropped from `stretches` was counted, so a session can
    /// still tell it apart from time that never was. nil in a day from before
    /// this was kept: such a day can't say what it dropped.
    var evicted: [DateInterval]?

    init(day: String) { self.day = day }

    var seconds: TimeInterval { totals.reduce(0) { $0 + max(0, $1.seconds) } }
    var isEmpty: Bool { totals.isEmpty && stretches.isEmpty }
    var hasTitles: Bool { ActivityRedaction.hasTitles(totals, stretches) }
    /// Every counted moment is accounted for by `recordedIntervals`.
    var knowsCoverage: Bool { !truncated || evicted != nil }
    /// When the time in `totals` was counted, as far as the day still knows.
    var recordedIntervals: [DateInterval] {
        (evicted ?? []) + stretches.compactMap { stretch in
            stretch.end > stretch.start ? DateInterval(start: stretch.start, end: stretch.end) : nil
        }
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The first key still kept, counting today as the first of `days` days.
    /// nil keeps everything.
    static func retentionStart(days: Int, today: Date, calendar: Calendar) -> String? {
        guard days > 0, let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return nil }
        return key(for: first, calendar: calendar)
    }

    /// Adds an observed stretch. One that continues the last is merged into
    /// it, so a day holds contexts rather than saves.
    mutating func add(_ stretch: FocusActivitySegment) {
        guard stretch.end > stretch.start else { return }
        credit(stretch)
        if let last = stretches.last, ActivityTimeline.touches(last, stretch), ActivityTimeline.sameContext(last, stretch) {
            stretches[stretches.count - 1].end = stretch.end
            if let url = stretch.url { stretches[stretches.count - 1].url = url }
        } else {
            stretches.append(stretch)
            if stretches.count > Self.stretchLimit {
                let excess = stretches.count - Self.stretchLimit
                // A day already cut short before this was kept stays unknown.
                if knowsCoverage { noteEvicted(stretches.prefix(excess)) }
                stretches.removeFirst(excess)
                truncated = true
            }
        }
    }

    /// Merged as it goes, so this grows with the gaps in a day, not its stretches.
    private mutating func noteEvicted(_ dropped: ArraySlice<FocusActivitySegment>) {
        var ranges = evicted ?? []
        for stretch in dropped where stretch.end > stretch.start {
            if let last = ranges.last, stretch.start <= last.end {
                ranges[ranges.count - 1] = DateInterval(start: last.start, end: max(last.end, stretch.end))
            } else {
                ranges.append(DateInterval(start: stretch.start, end: stretch.end))
            }
        }
        evicted = ranges
    }

    private mutating func credit(_ stretch: FocusActivitySegment) {
        func matches(_ row: FocusActivity, title: String?) -> Bool {
            row.appID == stretch.appID && row.site == stretch.site && row.title == title
        }
        if let index = totals.firstIndex(where: { matches($0, title: stretch.title) }) {
            totals[index].seconds += stretch.seconds
            totals[index].appName = stretch.appName
            return
        }
        let title = totals.count < Self.totalsLimit ? stretch.title : nil
        if let index = totals.firstIndex(where: { matches($0, title: title) }) {
            totals[index].seconds += stretch.seconds
        } else {
            totals.append(FocusActivity(appID: stretch.appID, appName: stretch.appName, site: stretch.site,
                                        title: title, seconds: stretch.seconds))
        }
    }

    /// Retracts recently observed time after an idle boundary. The retained
    /// stretches tell us exactly what to subtract; older time that has fallen
    /// outside the timeline limit remains in the totals.
    @discardableResult
    mutating func trim(after cutoff: Date, continuityAtLeast floor: Int) -> Bool {
        var changed = false
        var kept: [FocusActivitySegment] = []
        kept.reserveCapacity(stretches.count)
        for var stretch in stretches {
            guard stretch.continuity >= floor, stretch.end > cutoff else {
                kept.append(stretch)
                continue
            }
            let removed = stretch.end.timeIntervalSince(max(stretch.start, cutoff))
            guard removed > 0 else {
                kept.append(stretch)
                continue
            }
            changed = true
            debit(removed, from: stretch)
            if stretch.start < cutoff {
                stretch.end = cutoff
                kept.append(stretch)
            }
        }
        if changed {
            stretches = kept
            totals.removeAll { $0.seconds <= 0 }
        }
        return changed
    }

    private mutating func debit(_ seconds: TimeInterval, from stretch: FocusActivitySegment) {
        func matches(_ row: FocusActivity, title: String?) -> Bool {
            row.appID == stretch.appID && row.site == stretch.site && row.title == title
        }
        var remaining = seconds
        if let index = totals.firstIndex(where: { matches($0, title: stretch.title) }) {
            let removed = min(remaining, max(0, totals[index].seconds))
            totals[index].seconds -= removed
            remaining -= removed
        }
        // New names beyond totalsLimit contribute to the unnamed row, while
        // the timeline still retains the observed title.
        if remaining > 0, stretch.title != nil,
           let index = totals.firstIndex(where: { matches($0, title: nil) }) {
            totals[index].seconds = max(0, totals[index].seconds - remaining)
        }
    }

    mutating func removeTitles() {
        totals = ActivityRedaction.withoutTitles(totals)
        stretches = ActivityRedaction.withoutTitles(stretches)
    }

    /// This day as the views show it, without the apps.
    func hiding(_ apps: Set<String>) -> ActivityDayLog {
        guard !apps.isEmpty else { return self }
        var log = self
        log.remove(apps: apps)
        return log
    }

    /// Takes the apps out. A gap is left where they were, so their neighbors
    /// are not taken for one continuous stretch.
    mutating func remove(apps: Set<String>) {
        totals.removeAll { apps.contains($0.appID) }
        var kept: [FocusActivitySegment] = []
        var offset = 0
        for var stretch in stretches {
            if apps.contains(stretch.appID) { offset += 1; continue }
            stretch.continuity += offset
            kept.append(stretch)
        }
        stretches = kept
    }

    /// What a file may be trusted to hold, whatever is in it.
    var sanitized: ActivityDayLog {
        var log = self
        log.totals = totals.compactMap { row in
            guard row.seconds.isFinite, row.seconds > 0 else { return nil }
            var row = row
            row.site = ActivityTimeline.safeDaySite(row.site)
            return row
        }
        log.stretches = stretches.compactMap { stretch in
            guard stretch.end > stretch.start else { return nil }
            var stretch = stretch
            stretch.site = ActivityTimeline.safeDaySite(stretch.site)
            stretch.url = ActivityProbe.keptURL(stretch.url)
            return stretch
        }
        return log
    }

    /// The part of a stretch on each calendar day it touches, in order.
    static func split(_ stretch: FocusActivitySegment, calendar: Calendar) -> [(day: String, stretch: FocusActivitySegment)] {
        var pieces: [(String, FocusActivitySegment)] = []
        var piece = stretch
        while piece.end > piece.start {
            guard let next = calendar.dateInterval(of: .day, for: piece.start)?.end, next < piece.end, next > piece.start else {
                pieces.append((key(for: piece.start, calendar: calendar), piece))
                break
            }
            var part = piece
            part.end = next
            pieces.append((key(for: piece.start, calendar: calendar), part))
            piece.id = UUID().uuidString
            piece.start = next
        }
        return pieces
    }

    /// The stretches inside the ranges, cut to them. Times are kept as they
    /// were observed; nothing is credited outside a range.
    static func slice(_ stretches: [FocusActivitySegment], to ranges: [DateInterval]) -> [FocusActivitySegment] {
        var sliced: [FocusActivitySegment] = []
        for stretch in stretches {
            for range in ranges {
                let start = max(stretch.start, range.start), end = min(stretch.end, range.end)
                guard end > start else { continue }
                var part = stretch
                if start != stretch.start || end != stretch.end { part.id = "\(stretch.id)@\(start.timeIntervalSinceReferenceDate)" }
                part.start = start
                part.end = end
                sliced.append(part)
            }
        }
        return sliced.sorted { $0.start < $1.start }
    }
}
