import Foundation
import Testing
@testable import Nidus

/// Sessions and the daily record counting each second once, at the edges:
/// a session only partly in the record, and a day full enough to drop stretches.
@MainActor
@Suite struct ActivityAccuracyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(_ hour: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!.addingTimeInterval(hour * 3600)
    }
    private func stretch(_ from: Double, _ to: Double, app: String = "Word") -> FocusActivitySegment {
        FocusActivitySegment(start: at(from), end: at(to), appID: "id." + app, appName: app)
    }
    private func log(_ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: "2026-11-04")
        for stretch in stretches { log.add(stretch) }
        return log
    }
    private func session(_ from: Double, _ to: Double, timeline: [FocusActivitySegment]?, truncated: Bool = false) -> SessionEntry {
        var entry = SessionEntry(start: at(from), end: at(to), focused: (to - from) * 3600, planned: nil, outcome: .completed,
                                 goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = [FocusActivity(appID: "id.Word", appName: "Word", seconds: (to - from) * 3600)]
        entry.activitySegments = timeline
        entry.activityTimelineTruncated = truncated ? true : nil
        return entry
    }
    /// A day past the limit whose first hours have left `stretches`: minute
    /// long stretches, in a gapless run from 00:00.
    private func fullDay(extra: Int = 5) -> ActivityDayLog {
        var log = ActivityDayLog(day: "2026-11-04")
        let start = at(0)
        // Each app change stops the stretches merging into one.
        for index in 0..<(ActivityDayLog.stretchLimit + extra) {
            let from = start.addingTimeInterval(Double(index) * 10)
            log.add(FocusActivitySegment(start: from, end: from.addingTimeInterval(10),
                                         appID: index.isMultiple(of: 2) ? "id.Word" : "id.Mail", appName: "App"))
        }
        return log
    }

    // MARK: A session partly in the daily record

    @Test func aSessionPartlyInTheRecordAddsOnlyWhatIsMissing() {
        // Tracked 9 to 10; the session ran 9:30 to 11 with its own timeline.
        let scope = ActivityScope(logs: [log([stretch(9, 10)])],
                                  sessions: [session(9.5, 11, timeline: [stretch(9.5, 11)])], calendar: calendar)
        #expect(scope.totals.observed == 2 * 3600)
        #expect(scope.stretches.count == 2)
        #expect(scope.stretches.last?.end == at(11))
    }

    @Test func missingTimeReachesTheCategories() {
        let categorizer = ActivityCategorizer(categories: [], work: FocusCategory.workSeed)
        let scope = ActivityScope(logs: [log([stretch(9, 10)])],
                                  sessions: [session(9.5, 11, timeline: [stretch(9.5, 11)])], calendar: calendar)
        #expect(scope.categoryTotals(using: categorizer).reduce(0) { $0 + $1.seconds } == 2 * 3600)
    }

    @Test func aSessionWhollyInTheRecordAddsNothing() {
        let scope = ActivityScope(logs: [log([stretch(9, 12)])],
                                  sessions: [session(10, 11, timeline: [stretch(10, 11)])], calendar: calendar)
        #expect(scope.totals.observed == 3 * 3600)
        #expect(scope.stretches.count == 1)
    }

    @Test func momentsOfClockDisagreementAreNotMissingTime() {
        let scope = ActivityScope(logs: [log([stretch(9, 10)])],
                                  sessions: [session(9, 10, timeline: [stretch(9, 10.0001)])], calendar: calendar)
        #expect(scope.totals.observed == 3600)
    }

    @Test func pausesInASessionStayOut() {
        // The session's timeline has a hole from 10:30 to 10:45.
        let scope = ActivityScope(logs: [log([stretch(9, 10)])],
                                  sessions: [session(9.5, 11, timeline: [stretch(9.5, 10.5), stretch(10.75, 11)])], calendar: calendar)
        #expect(scope.totals.observed == 1.75 * 3600)
    }

    @Test func withoutATimelineAPartialSessionStaysOutRatherThanCountTwice() {
        let scope = ActivityScope(logs: [log([stretch(9, 10)])],
                                  sessions: [session(9.5, 11, timeline: nil), session(13, 14, timeline: [stretch(13, 15)], truncated: true)],
                                  calendar: calendar)
        #expect(scope.totals.observed == 3600 + 3600)
    }

    // MARK: A full day

    @Test func aFullDayRemembersWhatItDropped() {
        let log = fullDay()
        #expect(log.truncated)
        #expect(log.knowsCoverage)
        #expect(log.stretches.count == ActivityDayLog.stretchLimit)
        // Gapless, so the dropped stretches are one range.
        #expect(log.evicted?.count == 1)
        #expect(log.evicted?.first?.duration == 50)
    }

    @Test func dropsAcrossAGapStaySeparate() {
        var log = fullDay(extra: 0)
        log.stretches[0].end = log.stretches[0].start.addingTimeInterval(4)
        let late = at(23.9)
        log.add(FocusActivitySegment(start: late, end: late.addingTimeInterval(5), appID: "id.Late", appName: "Late"))
        log.add(FocusActivitySegment(start: late.addingTimeInterval(10), end: late.addingTimeInterval(15), appID: "id.Word", appName: "Word"))
        #expect(log.evicted?.count == 2)
    }

    @Test func aSessionInADroppedStretchIsNotCountedTwice() {
        let log = fullDay()
        let first = at(0).addingTimeInterval(1)
        let end = first.addingTimeInterval(30)
        var entry = SessionEntry(start: first, end: end, focused: 30, planned: nil, outcome: .completed,
                                 goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = [FocusActivity(appID: "id.Word", appName: "Word", seconds: 30)]
        let scope = ActivityScope(logs: [log], sessions: [entry], calendar: calendar)
        #expect(scope.totals.observed == log.seconds)
    }

    @Test func aDayCutShortBeforeThisWasKeptStaysAsItWas() throws {
        var old = fullDay()
        old.evicted = nil
        #expect(!old.knowsCoverage)
        // Further drops don't start an account that would look complete.
        let late = at(23.9)
        old.add(FocusActivitySegment(start: late, end: late.addingTimeInterval(5), appID: "id.Late", appName: "Late"))
        #expect(old.evicted == nil)
        // A partial session on such a day adds nothing, as before.
        let surviving = old.stretches[0].start
        let scope = ActivityScope(logs: [old], sessions: [session(0, surviving.timeIntervalSince(at(0)) / 3600 + 0.1,
                                                                  timeline: [stretch(0, surviving.timeIntervalSince(at(0)) / 3600 + 0.1)])],
                                  calendar: calendar)
        #expect(scope.totals.observed == old.seconds)
    }

    @Test func aDayFileWithoutTheNewFieldStillReads() throws {
        var old = log([stretch(9, 10)])
        old.truncated = true
        let data = try ActivityDayStore.encode(old)
        let decoded = try JSONDecoder().decode(ActivityDayLog.self, from: data)
        #expect(decoded.evicted == nil)
        #expect(!decoded.knowsCoverage)
        var kept = fullDay()
        kept = try JSONDecoder().decode(ActivityDayLog.self, from: ActivityDayStore.encode(kept))
        #expect(kept.evicted?.count == 1)
    }

    // MARK: Count as

    @Test func theActivityPageCountsAsThePopoverDoes() {
        var overrides = ActivityOverrides()
        overrides.set(.work, appID: "id.Word", site: nil)
        let interval = DateInterval(start: at(0), end: at(24))
        func key(_ overrides: ActivityOverrides) -> ActivityCacheKey {
            ActivityCacheKey(version: 0, dayVersion: 0, start: interval.start, end: interval.end, projectID: nil, focusOnly: false,
                             excluded: [], work: FocusCategory.workSeed, categories: [], overrides: overrides, categoryFilter: nil)
        }
        let popover = ActivityCategorizer(categories: [], work: FocusCategory.workSeed, overrides: overrides)
        #expect(key(overrides).categorizer.category(appID: "id.Word", site: nil) == ActivityCategorizer.workID)
        #expect(key(overrides).categorizer.category(appID: "id.Word", site: nil) == popover.category(appID: "id.Word", site: nil))
        // A change to "Count as" alone must make the page work the groups out again.
        #expect(key(overrides) != key(ActivityOverrides()))
    }

    // MARK: CSV

    @Test func aWindowsLineBreakInATitleIsQuoted() {
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(FocusActivitySegment(start: at(9), end: at(10), appID: "id.Word", appName: "Word", title: "two\r\nlines"))
        let csv = ActivityExport.csv(logs: [log], sessions: [], calendar: calendar)
        #expect(csv.contains("\"two\r\nlines\""))
    }
}
