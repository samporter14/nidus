//
//  PolishTests.swift
//  NidusTests
//
//  1.2: the heads-up before a snooze runs out, ending one early, and the
//  streak said once a day on the wrap-up card.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct SnoozeEndingTests {
    @Test func listsOnlySnoozesInsideTheLeadSoonestFirst() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.snooze("youtube.com", for: 3 * minute)
        h.engine.snooze("com.tinyspeck.slackmacgap", for: 1 * minute)
        #expect(h.engine.snoozesEnding(within: 30).isEmpty, "neither ends within 30 seconds yet")

        h.clock.advance(35)
        #expect(h.engine.snoozesEnding(within: 30).map(\.item) == ["com.tinyspeck.slackmacgap"])

        h.clock.advance(2 * minute)
        h.engine.tick()
        #expect(h.engine.snoozesEnding(within: 30).map(\.item) == ["youtube.com"],
                "Slack's has ended and gone; YouTube's is 25 seconds off")
    }

    @Test func aSnoozeThatHasRunOutIsNotEnding() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.snooze("youtube.com", for: minute)
        h.clock.advance(minute + 1)
        #expect(h.engine.snoozesEnding(within: 30).isEmpty)
    }

    @Test func endingASnoozeEarlyBlocksAgainAtOnce() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.snooze("youtube.com", for: 3 * minute)
        #expect(h.engine.enforcement?.websites.contains("youtube.com") == false)

        h.engine.endSnooze("youtube.com")
        #expect(h.engine.session?.snoozes.isEmpty == true)
        #expect(h.engine.enforcement?.websites.contains("youtube.com") == true)
        #expect(h.events.last == .snoozeEnded("youtube.com"))

        let count = h.events.all.count
        h.engine.endSnooze("youtube.com")
        #expect(h.events.all.count == count, "ending one that is not snoozed does nothing")
    }
}

struct StreakMilestoneTests {
    typealias S = StatsTests

    @Test func theDaysFirstSessionNamesTheStreak() {
        let today = S.entry(0, minutes: 25)
        let sessions = [S.entry(-2, minutes: 30), S.entry(-1, minutes: 45), today]
        #expect(FocusStats.streakMilestone(for: today, in: sessions, calendar: S.calendar) == 3)
    }

    @Test func laterSessionsThatDaySayNothing() {
        let first = S.entry(0, minutes: 25)
        var second = S.entry(0, minutes: 25)
        second.start = first.end.addingTimeInterval(600)
        second.end = second.start.addingTimeInterval(25 * 60)
        let sessions = [S.entry(-1, minutes: 45), first, second]
        #expect(FocusStats.streakMilestone(for: second, in: sessions, calendar: S.calendar) == nil)
    }

    @Test func aFirstDayIsNotAStreak() {
        let today = S.entry(0, minutes: 25)
        #expect(FocusStats.streakMilestone(for: today, in: [S.entry(-3, minutes: 30), today], calendar: S.calendar) == nil)
    }
}
