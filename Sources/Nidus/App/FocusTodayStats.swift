//
//  FocusTodayStats.swift
//  Nidus
//
//  Today's focus, for the quiet line at the foot of the idle popover. It
//  lives here, not in FocusHistory.swift, so the Stats page's own changes
//  to FocusStats merge without it.
//

import Foundation

extension FocusStats {
    /// Time focused today, by the `now` and calendar the stats were made
    /// with. It is the last day of the last week that is not in the future,
    /// which is today for any `weeks` of one or more.
    var focusedToday: TimeInterval {
        weeks.last?.last(where: { !$0.isFuture })?.focused ?? 0
    }
}
