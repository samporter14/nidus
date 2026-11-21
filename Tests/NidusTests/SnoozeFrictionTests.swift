//
//  SnoozeFrictionTests.swift
//  NidusTests
//
//  Snooze friction and count: the wait grows with each repeat of the same
//  item within a session, and how often each item was snoozed is recorded
//  and shown on the finish card and in the weekly recap.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct SnoozeEscalationTests {
    static let key = "reddit.com"

    func decide(_ h: Harness, wait: Int, key: String = key) -> SnoozeWait.Decision {
        SnoozeWait.decide(key: key, name: key, waitSeconds: wait, session: h.engine.session,
                          existing: nil, now: h.clock.now)
    }

    /// Snoozes `key` and lets it run out again, as a repeat would.
    func snoozeAndExpire(_ h: Harness, _ key: String = key) {
        h.engine.snooze(key)
        h.engine.endSnooze(key)
    }

    func seconds(_ decision: SnoozeWait.Decision) -> Int? {
        if case .wait(let w) = decision { return w.seconds }
        return nil
    }

    @Test func theSequenceGrowsThenCapsAt120() {
        let expected = [10, 30, 60, 120, 120, 120]
        #expect((0..<6).map { SnoozeWait.escalatedSeconds(configured: 10, prior: $0) } == expected)
        let h = Harness()
        h.engine.start(plan(25, websites: [Self.key]))
        var seen: [Int] = []
        for _ in 0..<6 {
            seen.append(seconds(decide(h, wait: 10)) ?? -1)
            snoozeAndExpire(h)
        }
        #expect(seen == expected)
    }

    @Test func noConfiguredWaitStillGrowsOnTheSecondSnooze() {
        let h = Harness()
        h.engine.start(plan(25, websites: [Self.key]))
        #expect(decide(h, wait: 0) == .snoozeNow)
        snoozeAndExpire(h)
        #expect(seconds(decide(h, wait: 0)) == 30)
    }

    @Test func neverShorterThanTheConfiguredWait() {
        #expect(SnoozeWait.escalatedSeconds(configured: 30, prior: 1) == 30)
        #expect(SnoozeWait.escalatedSeconds(configured: 30, prior: 0) == 30)
        #expect(SnoozeWait.escalatedSeconds(configured: 30, prior: 2) == 60)
    }

    @Test func eachItemCountsOnItsOwn() {
        let h = Harness()
        h.engine.start(plan(25, apps: ["com.tinyspeck.slackmacgap"], websites: [Self.key]))
        snoozeAndExpire(h)
        snoozeAndExpire(h)
        #expect(seconds(decide(h, wait: 10)) == 60)
        #expect(seconds(decide(h, wait: 10, key: "com.tinyspeck.slackmacgap")) == 10, "another item starts from the configured wait")
    }

    @Test func aNewSessionStartsOver() {
        let h = Harness()
        h.engine.start(plan(25, websites: [Self.key]))
        snoozeAndExpire(h)
        snoozeAndExpire(h)
        #expect(h.engine.session?.snoozeCounts[Self.key] == 2)
        h.engine.end()
        h.engine.start(plan(25, websites: [Self.key]))
        #expect(h.engine.session?.snoozeCounts.isEmpty == true)
        #expect(seconds(decide(h, wait: 10)) == 10)
    }

    @Test func strictModeStillHasNoSnooze() {
        let h = Harness()
        h.engine.start(strictPlan())
        #expect(decide(h, wait: 10) == .refuse)
        h.engine.snooze(Self.key)
        #expect(h.engine.session?.snoozeCounts.isEmpty == true)
    }

    @Test func aRelaunchKeepsTheCounts() {
        let h = Harness()
        h.engine.start(plan(25, websites: [Self.key]))
        snoozeAndExpire(h)
        let (engine, _) = h.relaunch()
        #expect(engine.session?.snoozeCounts == [Self.key: 1])
    }
}

@MainActor
struct SnoozeCountRecordTests {
    @Test func theEndedSessionKeepsTheCounts() throws {
        let h = Harness()
        h.engine.start(plan(25))
        for _ in 0..<3 { h.engine.snooze("youtube.com"); h.engine.endSnooze("youtube.com") }
        var state = try #require(h.engine.session)
        state.focusedTime = 600
        let entry = try #require(SessionEntry(ended: state, outcome: .completed))
        #expect(entry.snoozeCounts == ["youtube.com": 3])
    }

    @Test func historyWrittenBeforeCountsDecodesWithNone() throws {
        var entry = SessionEntry(start: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                 end: Date(timeIntervalSinceReferenceDate: 800_001_500), focused: 1500, planned: 1500,
                                 outcome: .completed, snoozeCounts: ["youtube.com": 2])
        let round = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(entry))
        #expect(round.snoozeCounts == ["youtube.com": 2])

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["snoozeCounts"] = nil
        let old = try JSONDecoder().decode(SessionEntry.self, from: JSONSerialization.data(withJSONObject: object))
        entry.snoozeCounts = [:]
        #expect(old.snoozeCounts.isEmpty)
        #expect(old.focused == 1500)

        object["snoozeCounts"] = "lots"
        let wrong = try JSONDecoder().decode(SessionEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(wrong.snoozeCounts.isEmpty, "a field written wrongly loses only itself")
    }

    @Test func aSessionSavedBeforeCountsLoadsWithNone() throws {
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(MigrationTests.legacySession.utf8))
        #expect(record.session?.snoozeCounts == [:])
    }
}

struct SnoozeSummaryTests {
    @Test func readsAsTimesAndSingular() {
        #expect(SnoozeSummary.text(counts: ["reddit.com": 4]) == "Snoozed reddit.com 4 times")
        #expect(SnoozeSummary.text(counts: ["reddit.com": 1]) == "Snoozed reddit.com 1 time")
    }

    @Test func showsTheTopTwoWithNames() {
        let counts = ["reddit.com": 4, "com.tinyspeck.slackmacgap": 2, "x.com": 1]
        #expect(SnoozeSummary.text(counts: counts, names: ["com.tinyspeck.slackmacgap": "Slack"])
                == "Snoozed reddit.com 4 times, Slack 2 times")
    }

    @Test func nothingSnoozedSaysNothing() {
        #expect(SnoozeSummary.text(counts: [:]) == nil)
        #expect(SnoozeSummary.text(counts: ["reddit.com": 0]) == nil)
    }

    @Test func tiesGoByName() {
        #expect(SnoozeSummary.text(counts: ["b.com": 2, "a.com": 2, "c.com": 2]) == "Snoozed a.com 2 times, b.com 2 times")
    }

    @Test func theWeeklyRecapAddsItToItsLine() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        let start = monday.addingTimeInterval(36_000)
        func entry(_ counts: [String: Int]) -> SessionEntry {
            SessionEntry(start: start, end: start.addingTimeInterval(1800), focused: 1800, planned: 1800,
                         outcome: .completed, snoozeCounts: counts)
        }
        let recap = try #require(WeeklyRecap(sessions: [entry(["reddit.com": 2]), entry(["reddit.com": 3])],
                                             weekStarting: monday, calendar: cal))
        #expect(recap.snoozeLine == "Snoozed reddit.com 5 times")
        #expect(recap.detail.hasSuffix("Snoozed reddit.com 5 times"))
        let quiet = try #require(WeeklyRecap(sessions: [entry([:])], weekStarting: monday, calendar: cal))
        #expect(quiet.snoozeLine == nil)
        #expect(!quiet.detail.contains("Snoozed"))
    }
}
