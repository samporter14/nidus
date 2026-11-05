//
//  TodayOverview.swift
//  Nidus
//
//  Today at a glance, for the popover: time at the Mac, time focused, the day
//  as a ribbon, and the few things that took the most of it. A value the
//  views draw, built from the same scope and ribbon as the Activity page.
//

import Foundation

/// Today's time by group, for one line: the three longest, then the rest
/// as Other. Uncategorized is one of the groups, so it is named only when it
/// is among the three longest, and is otherwise part of Other: a day that is
/// mostly uncategorized says so, and a day that is mostly sorted is not
/// cluttered with a remainder nobody sorted.
struct CategorySplit: Equatable {
    struct Part: Equatable, Identifiable {
        let id: String
        let name: String
        let seconds: TimeInterval
    }

    static let otherID = "__other__"
    static let named = 3

    let parts: [Part]

    /// nil when nothing is categorized at all, so a fresh install shows no line.
    init?(totals: [ActivityCategoryTotal]) {
        guard totals.contains(where: { $0.id != ActivityCategorizer.uncategorizedID && $0.seconds > 0 }) else { return nil }
        let ranked = totals.filter { $0.seconds > 0 }.sorted { ($1.seconds, $0.name) < ($0.seconds, $1.name) }
        var parts = ranked.prefix(Self.named).map { Part(id: $0.id, name: $0.name, seconds: $0.seconds) }
        let rest = ranked.dropFirst(Self.named).reduce(0) { $0 + $1.seconds }
        if rest > 0 { parts.append(Part(id: Self.otherID, name: "Other", seconds: rest)) }
        self.parts = parts
    }

    /// "Work 3h 10m · AI 1h 05m", the first `count` parts.
    func text(first count: Int? = nil) -> String {
        parts.prefix(count ?? parts.count)
            .map { "\($0.name) \(ActivityDuration.string($0.seconds))" }
            .joined(separator: " \u{00B7} ")
    }
}

struct TodayOverview {
    enum State: Equatable {
        /// Something was counted today.
        case data
        /// Tracking is on and nothing has been counted yet.
        case empty
        /// Tracking is off and no session ran today.
        case off
    }

    /// How many rows each list keeps.
    static let rowLimit = 3

    let state: State
    /// Time seen in front, from the daily record or from today's sessions.
    let atMac: TimeInterval
    /// Time in focus sessions, the one running now included.
    let focused: TimeInterval
    let ribbon: ActivityRibbon
    let apps: [ActivityRank]
    let websites: [ActivityRank]
    let documents: [ActivityRank]
    /// nil until something is sorted into a group.
    let categorySplit: CategorySplit?
    /// The top of each uncapped list, so bars across a list share one scale.
    private let leaders: [ActivityListKind: TimeInterval]

    func rows(_ kind: ActivityListKind) -> [ActivityRank] {
        switch kind {
        case .apps: return apps
        case .websites: return websites
        case .documents: return documents
        // The popover shows categories as a line, not a list.
        case .categories: return []
        }
    }

    /// The longest time in the whole list, not only the rows kept.
    func maximum(for kind: ActivityListKind) -> TimeInterval { leaders[kind] ?? 0 }

    /// `liveFocused` is the running session's focused time, pauses excluded.
    /// The totals count finished sessions only, so it is added here.
    init(log: ActivityDayLog, sessions: [SessionEntry], live: ActivityRibbon.Focus?, liveFocused: TimeInterval,
         tracking: Bool, now: Date, categorizer: ActivityCategorizer, calendar: Calendar = .current) {
        let today = sessions.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let day = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
        let scope = ActivityScope(logs: [log], sessions: today, live: live.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                                  calendar: calendar)
        var ribbon = ActivityRibbon(stretches: scope.stretches, sessions: today, live: live, day: day, now: now, calendar: calendar)

        // The day so far, rather than a working day: from the hour of the
        // first thing shown to now.
        let times = ribbon.blocks.flatMap { [$0.start, $0.end] } + ribbon.focus.flatMap { [$0.start, $0.end] }
        let first = times.min() ?? now.addingTimeInterval(-3600)
        let hour = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let start = max(times.isEmpty ? first : hour, day.start)
        ribbon.span = DateInterval(start: start, end: max(now, start.addingTimeInterval(3600)))

        atMac = scope.totals.observed
        focused = scope.totals.focused + max(0, liveFocused)
        self.ribbon = ribbon
        apps = Array(scope.totals.apps.prefix(Self.rowLimit))
        websites = Array(scope.totals.sites.prefix(Self.rowLimit))
        documents = Array(scope.totals.documents.prefix(Self.rowLimit))
        categorySplit = CategorySplit(totals: scope.categoryTotals(using: categorizer))
        leaders = [.apps: scope.totals.apps.first?.seconds ?? 0, .websites: scope.totals.sites.first?.seconds ?? 0,
                   .documents: scope.totals.documents.first?.seconds ?? 0]

        if atMac > 0 || focused > 0 || live != nil || !ribbon.isEmpty {
            state = .data
        } else {
            state = tracking ? .empty : .off
        }
    }
}
