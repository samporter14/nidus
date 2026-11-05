//
//  TodayOverview.swift
//  Nidus
//
//  Today at a glance, for the popover: time at the Mac, time focused, the day
//  as a ribbon, and the few things that took the most of it. A value the
//  views draw, built from the same scope and ribbon as the Activity page.
//

import Foundation

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
    /// The top of each uncapped list, so bars across a list share one scale.
    private let leaders: [ActivityListKind: TimeInterval]

    func rows(_ kind: ActivityListKind) -> [ActivityRank] {
        switch kind {
        case .apps: return apps
        case .websites: return websites
        case .documents: return documents
        }
    }

    /// The longest time in the whole list, not only the rows kept.
    func maximum(for kind: ActivityListKind) -> TimeInterval { leaders[kind] ?? 0 }

    /// `liveFocused` is the running session's focused time, pauses excluded.
    /// The totals count finished sessions only, so it is added here.
    init(log: ActivityDayLog, sessions: [SessionEntry], live: ActivityRibbon.Focus?, liveFocused: TimeInterval,
         tracking: Bool, now: Date, calendar: Calendar = .current) {
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
        leaders = [.apps: scope.totals.apps.first?.seconds ?? 0, .websites: scope.totals.sites.first?.seconds ?? 0,
                   .documents: scope.totals.documents.first?.seconds ?? 0]

        if atMac > 0 || focused > 0 || live != nil || !ribbon.isEmpty {
            state = .data
        } else {
            state = tracking ? .empty : .off
        }
    }
}
