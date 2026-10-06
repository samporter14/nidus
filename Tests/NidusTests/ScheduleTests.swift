//
//  ScheduleTests.swift
//  NidusTests
//
//  Weekly schedules: when the next one starts (across the 2026 US clock
//  changes), what happens at a start, a missed start, an overlap, and an
//  edit. Every expected time is written as an absolute instant with its
//  offset, never built with the Foundation calls under test. Nothing here
//  starts a timer, a session or a card: the scheduler is run by hand against
//  a fake host.
//

import Foundation
import Testing
@testable import Nidus

// MARK: - Helpers

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// "2026-03-08T03:30:00-04:00", read as the instant it names.
private func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else { fatalError("bad date \(text)") }
    return date
}

private func schedule(_ id: String = "a", days: Set<Int> = FocusSchedule.workweek,
                      _ start: (Int, Int) = (9, 0), _ end: (Int, Int) = (12, 0),
                      isOn: Bool = true, goal: String = "") -> FocusSchedule {
    FocusSchedule(id: id, isOn: isOn, weekdays: days,
                  start: ScheduleTime(hour: start.0, minute: start.1), end: ScheduleTime(hour: end.0, minute: end.1),
                  categoryIDs: ["social"], goal: goal)
}

private func next(after text: String, _ schedules: [FocusSchedule]) -> FocusSchedule.Occurrence? {
    FocusSchedule.nextStart(after: at(text), schedules: schedules, calendar: newYork)
}

// Calendar weekdays.
private let sunday = 1, monday = 2, tuesday = 3, thursday = 5, friday = 6, saturday = 7

// MARK: - The next start

struct NextStartTests {
    @Test func aWeekdayScheduleSkipsTheWeekend() throws {
        // Friday 12:30; the next 9:00 weekday is Monday, after the March clock change.
        let found = try #require(next(after: "2026-03-06T12:30:00-05:00", [schedule()]))
        #expect(found.start == at("2026-03-09T09:00:00-04:00"))
        #expect(found.end == at("2026-03-09T12:00:00-04:00"))
    }

    @Test func aStartBeforeTodaysStartIsToday() throws {
        let found = try #require(next(after: "2026-03-09T08:59:59-04:00", [schedule()]))
        #expect(found.start == at("2026-03-09T09:00:00-04:00"))
    }

    @Test func aStartEqualToNowIsRunningNotNext() throws {
        let now = at("2026-03-09T09:00:00-04:00")
        let found = try #require(FocusSchedule.nextStart(after: now, schedules: [schedule()], calendar: newYork))
        #expect(found.start == at("2026-03-10T09:00:00-04:00"), "the 9:00 that is starting is not the next one")
        let running = FocusSchedule.inProgress(at: now, schedules: [schedule()], calendar: newYork)
        #expect(running.map(\.start) == [now], "it is in progress the instant it starts")
        #expect(FocusSchedule.inProgress(at: now.addingTimeInterval(-0.001), schedules: [schedule()], calendar: newYork).isEmpty)
    }

    @Test func aStartThatHasPassedWrapsToNextWeek() throws {
        // A Sunday-only schedule, asked on a Sunday after it started.
        let sundays = schedule(days: [sunday])
        let found = try #require(next(after: "2026-03-15T10:00:00-04:00", [sundays]))
        #expect(found.start == at("2026-03-22T09:00:00-04:00"))
        // And on the Saturday before, it is the next day.
        let saturdayNight = try #require(next(after: "2026-03-14T23:59:00-04:00", [sundays]))
        #expect(saturdayNight.start == at("2026-03-15T09:00:00-04:00"))
    }

    @Test func theYearTurns() throws {
        let fridays = schedule(days: [friday])
        let found = try #require(next(after: "2026-12-31T23:00:00-05:00", [fridays]))
        #expect(found.start == at("2027-01-01T09:00:00-05:00"))
    }

    @Test func nothingWhenNothingIsOn() {
        #expect(next(after: "2026-03-09T08:00:00-04:00", []) == nil)
        #expect(next(after: "2026-03-09T08:00:00-04:00", [schedule(isOn: false)]) == nil)
        #expect(next(after: "2026-03-09T08:00:00-04:00", [schedule(days: [])]) == nil)
        #expect(FocusSchedule.inProgress(at: at("2026-03-09T10:00:00-04:00"), schedules: [schedule(isOn: false)], calendar: newYork).isEmpty)
    }

    @Test func theEarliestOfSeveralWinsAndOffOnesAreIgnored() throws {
        let early = schedule("early", days: [monday], (7, 30), (8, 30), isOn: false)
        let lunch = schedule("lunch", days: [monday], (12, 0), (13, 0))
        let evening = schedule("evening", days: FocusSchedule.everyDay, (19, 0), (21, 0))
        let found = try #require(next(after: "2026-03-09T06:00:00-04:00", [evening, early, lunch]))
        #expect(found.schedule.id == "lunch")
        #expect(found.start == at("2026-03-09T12:00:00-04:00"))
    }

    // MARK: Clock changes

    @Test func springForwardMovesAStartInTheSkippedHourToWhereItWouldHaveBeen() throws {
        // Sunday March 8: 2:00 AM does not happen; the clocks go to 3:00.
        // 2:30 is read as 3:30, so a window that ends at 4:00 is 30 minutes.
        let sundays = schedule(days: [sunday], (2, 30), (4, 0))
        let found = try #require(next(after: "2026-03-07T12:00:00-05:00", [sundays]))
        #expect(found.start == at("2026-03-08T03:30:00-04:00"))
        #expect(found.end == at("2026-03-08T04:00:00-04:00"))
        #expect(found.duration == 30 * 60)
    }

    @Test func springForwardKeepsAWindowInsideTheSkippedHour() throws {
        let sundays = schedule(days: [sunday], (2, 15), (2, 45))
        let found = try #require(next(after: "2026-03-07T12:00:00-05:00", [sundays]))
        #expect(found.start == at("2026-03-08T03:15:00-04:00"))
        #expect(found.end == at("2026-03-08T03:45:00-04:00"))
    }

    @Test func springForwardShortensAWindowThatCrossesIt() throws {
        // 1:00 to 3:00 on the wall clock is one real hour that day.
        let sundays = schedule(days: [sunday], (1, 0), (3, 0))
        let found = try #require(next(after: "2026-03-07T12:00:00-05:00", [sundays]))
        #expect(found.start == at("2026-03-08T01:00:00-05:00"))
        #expect(found.end == at("2026-03-08T03:00:00-04:00"))
        #expect(found.duration == 3600)
    }

    @Test func aDailyNineAmFollowsTheClockThroughSpringForward() throws {
        let daily = schedule(days: FocusSchedule.everyDay)
        let saturdayStart = try #require(next(after: "2026-03-06T12:00:00-05:00", [daily]))
        #expect(saturdayStart.start == at("2026-03-07T09:00:00-05:00"))
        let sundayStart = try #require(FocusSchedule.nextStart(after: saturdayStart.start, schedules: [daily], calendar: newYork))
        #expect(sundayStart.start == at("2026-03-08T09:00:00-04:00"))
        #expect(sundayStart.start.timeIntervalSince(saturdayStart.start) == 23 * 3600, "the day was 23 hours")
    }

    @Test func fallBackStartsARepeatedTimeOnce() throws {
        // Sunday November 1: 1:00 to 2:00 happens twice. 1:30 is the first one.
        let sundays = schedule(days: [sunday], (1, 30), (3, 0))
        let found = try #require(next(after: "2026-10-31T12:00:00-04:00", [sundays]))
        #expect(found.start == at("2026-11-01T01:30:00-04:00"))
        #expect(found.end == at("2026-11-01T03:00:00-05:00"))
        #expect(found.duration == 150 * 60)

        // After the first 1:30, and after the second, the next is a week on.
        let afterFirst = try #require(next(after: "2026-11-01T01:45:00-04:00", [sundays]))
        #expect(afterFirst.start == at("2026-11-08T01:30:00-05:00"))
        let afterSecond = try #require(next(after: "2026-11-01T01:15:00-05:00", [sundays]))
        #expect(afterSecond.start == at("2026-11-08T01:30:00-05:00"))
    }

    @Test func aDailyOneThirtyDoesNotFireTwiceInTheRepeatedHour() throws {
        let daily = schedule(days: FocusSchedule.everyDay, (1, 30), (2, 30))
        let first = try #require(next(after: "2026-11-01T00:00:00-04:00", [daily]))
        #expect(first.start == at("2026-11-01T01:30:00-04:00"))
        let following = try #require(FocusSchedule.nextStart(after: first.start, schedules: [daily], calendar: newYork))
        #expect(following.start == at("2026-11-02T01:30:00-05:00"))
        // The second 1:30 is inside the window that began at the first.
        let running = FocusSchedule.inProgress(at: at("2026-11-01T01:30:00-05:00"), schedules: [daily], calendar: newYork)
        #expect(running.map(\.start) == [first.start])
    }

    @Test func aWindowAcrossTheRepeatedHourIsMeasuredInRealTime() throws {
        // 1:30 to 2:00 on November 1: the clock reads 1:30 to 1:59, then 1:00 to 2:00 again.
        let sundays = schedule(days: [sunday], (1, 30), (2, 0))
        let found = try #require(next(after: "2026-10-31T12:00:00-04:00", [sundays]))
        #expect(found.start == at("2026-11-01T01:30:00-04:00"))
        #expect(found.end == at("2026-11-01T02:00:00-05:00"))
        #expect(found.duration == 90 * 60)
    }
}

// MARK: - What to do with a start

struct DecisionTests {
    private let run = FocusSchedule.Occurrence(schedule: schedule(), start: at("2026-03-09T09:00:00-04:00"),
                                               end: at("2026-03-09T12:00:00-04:00"))

    @Test func anOnTimeStartRunsToTheEndOfTheWindow() {
        #expect(FocusSchedule.decide(run, now: run.start) == .start(minutes: 180, missed: false))
        // A timer is never exact: a second and a half late still ends at 12:00.
        #expect(FocusSchedule.decide(run, now: run.start.addingTimeInterval(1.5)) == .start(minutes: 180, missed: false))
    }

    @Test func aStartWithinTwoMinutesIsStillOnTime() {
        #expect(FocusSchedule.decide(run, now: run.start.addingTimeInterval(120)) == .start(minutes: 178, missed: false))
        #expect(FocusSchedule.decide(run, now: run.start.addingTimeInterval(121)) == .start(minutes: 178, missed: true))
    }

    @Test func aMissedStartIsMadeUpToTheEndOfTheWindow() {
        let wake = at("2026-03-09T10:15:00-04:00")
        #expect(FocusSchedule.decide(run, now: wake) == .start(minutes: 105, missed: true))
    }

    @Test func aMissedStartNeedsFiveMinutesLeft() {
        #expect(FocusSchedule.decide(run, now: at("2026-03-09T11:55:00-04:00")) == .start(minutes: 5, missed: true))
        #expect(FocusSchedule.decide(run, now: at("2026-03-09T11:55:01-04:00")) == .skip(.tooLate))
        #expect(FocusSchedule.decide(run, now: at("2026-03-09T11:59:00-04:00")) == .skip(.tooLate))
    }

    @Test func aShortWindowOnTimeIsNotHeldToTheFiveMinuteRule() {
        let short = FocusSchedule.Occurrence(schedule: schedule(), start: at("2026-03-09T09:00:00-04:00"),
                                             end: at("2026-03-09T09:03:00-04:00"))
        #expect(FocusSchedule.decide(short, now: short.start) == .start(minutes: 3, missed: false))
    }

    @Test func aSessionIsNeverOpenEnded() {
        // Under a minute left would round to 0, which means no end at all.
        #expect(FocusSchedule.decide(run, now: run.end) == .skip(.tooLate))
        #expect(FocusSchedule.decide(run, now: run.end.addingTimeInterval(-30)) == .skip(.tooLate))
        let oneMinute = FocusSchedule.Occurrence(schedule: schedule(), start: run.start, end: run.start.addingTimeInterval(60))
        #expect(FocusSchedule.decide(oneMinute, now: run.start.addingTimeInterval(30)) == .skip(.tooLate))
        #expect(FocusSchedule.decide(oneMinute, now: run.start) == .start(minutes: 1, missed: false))
    }

    @Test func minutesDropAPartialMinuteExceptTheSlack() {
        let end = at("2026-03-09T14:00:00-04:00")
        #expect(FocusSchedule.minutes(until: end, from: at("2026-03-09T13:20:30-04:00"), slack: 0) == 39)
        #expect(FocusSchedule.minutes(until: end, from: at("2026-03-09T13:20:00-04:00"), slack: 0) == 40)
        #expect(FocusSchedule.minutes(until: end, from: at("2026-03-09T13:20:05-04:00")) == 40, "ten seconds of slack")
        #expect(FocusSchedule.minutes(until: end, from: at("2026-03-09T13:59:30-04:00"), slack: 0) == nil)
    }

    @Test func handledIsPerScheduleAndRemembersTheLatestRun() {
        let handled = ["a": run.start]
        #expect(FocusSchedule.isHandled(run, in: handled))
        let tomorrow = FocusSchedule.Occurrence(schedule: run.schedule, start: run.start.addingTimeInterval(86_400),
                                                end: run.end.addingTimeInterval(86_400))
        #expect(!FocusSchedule.isHandled(tomorrow, in: handled))
        let other = FocusSchedule.Occurrence(schedule: schedule("b"), start: run.start, end: run.end)
        #expect(!FocusSchedule.isHandled(other, in: handled))
    }
}

// MARK: - Editing a window

struct ScheduleEditTests {
    @Test func movingTheStartMovesTheEndAlong() {
        var s = schedule()
        s.setStart(ScheduleTime(hour: 10, minute: 30))
        #expect(s.start == ScheduleTime(hour: 10, minute: 30))
        #expect(s.end == ScheduleTime(hour: 13, minute: 30))
    }

    @Test func theEndStopsAtTheEndOfTheDay() {
        var s = schedule()
        s.setStart(ScheduleTime(hour: 23, minute: 0))
        #expect(s.end == ScheduleTime(hour: 23, minute: 59))
        s.setStart(ScheduleTime(hour: 23, minute: 59))
        #expect(s.start == ScheduleTime(hour: 23, minute: 58))
        #expect(s.end > s.start)
    }

    @Test func anEndBeforeTheStartIsHeldAMinuteAfterIt() {
        var s = schedule()
        s.setEnd(ScheduleTime(hour: 8, minute: 0))
        #expect(s.end == ScheduleTime(hour: 9, minute: 1))
        s.setEnd(ScheduleTime(hour: 17, minute: 15))
        #expect(s.end == ScheduleTime(hour: 17, minute: 15))
    }

    @Test func aStoredScheduleReadsBackAndToleratesMissingFields() throws {
        var s = schedule("x", days: [monday, thursday], (13, 30), (15, 0), goal: "Deep work")
        s.strict = true
        s.mode = .allow
        let data = try JSONEncoder().encode([s])
        #expect(try JSONDecoder().decode([FocusSchedule].self, from: data) == [s])

        // A list written by a version with fewer (or more) fields still reads.
        let sparse = Data(#"[{"id":"y","weekdays":[2],"mode":"somethingNew","extra":1}]"#.utf8)
        let decoded = try JSONDecoder().decode([FocusSchedule].self, from: sparse)
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "y" && decoded[0].weekdays == [2])
        #expect(decoded[0].isOn && decoded[0].mode == .block && !decoded[0].strict && decoded[0].goal.isEmpty)
    }
}

// MARK: - Saying it

struct ScheduleSummaryTests {
    private let categories = FocusCategory.presets

    /// macOS writes a narrow no-break space before AM and PM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func theSummaryNamesDaysTimesAndCategories() {
        var s = schedule(days: FocusSchedule.workweek, (9, 0), (12, 0))
        s.categoryIDs = ["social", "messaging"]
        #expect(plain(s.summary(categories: categories, calendar: newYork)) == "Weekdays, 9:00 AM to 12:00 PM · Social, Messaging")
    }

    @Test func daysAreNamedFromTheWeeksFirst() {
        #expect(schedule(days: FocusSchedule.everyDay).daysSummary(calendar: newYork) == "Every day")
        #expect(schedule(days: FocusSchedule.weekend).daysSummary(calendar: newYork) == "Weekends")
        #expect(schedule(days: [monday, 4, friday]).daysSummary(calendar: newYork) == "Mon, Wed, Fri")
        #expect(schedule(days: [saturday, sunday, monday]).daysSummary(calendar: newYork) == "Sun, Mon, Sat")
        var mondayFirst = newYork
        mondayFirst.firstWeekday = 2
        #expect(schedule(days: [saturday, sunday, monday]).daysSummary(calendar: mondayFirst) == "Mon, Sat, Sun")
        #expect(schedule(days: []).daysSummary(calendar: newYork) == "No days")
    }

    @Test func categoriesCountOnceTheNamesStopFitting() {
        var s = schedule()
        s.categoryIDs = ["social", "video", "news"]
        #expect(s.categorySummary(categories: categories) == "3 categories")
        s.categoryIDs = ["mail"]
        s.mode = .allow
        #expect(s.categorySummary(categories: categories) == "Only Mail allowed")
        s.categoryIDs = ["deleted"]
        #expect(s.categorySummary(categories: categories) == "Nothing allowed")
        s.mode = .block
        #expect(s.categorySummary(categories: categories) == "Nothing to block")
    }
}

// MARK: - Running them

@MainActor
final class FakeScheduleHost: ScheduleHost {
    var schedules: [FocusSchedule] = []
    var scheduleHandled: [String: Date] = [:]
    var isSessionOrBreakOn = false
    var startSucceeds = true
    var started: [(id: String, minutes: Int, asks: Bool, missed: Bool)] = []
    var headsUps: [FocusSchedule.Occurrence] = []
    var logs: [String] = []

    func startScheduled(_ occurrence: FocusSchedule.Occurrence, minutes: Int, asksBrowserAccess: Bool, missed: Bool) -> Bool {
        guard startSucceeds else { return false }
        started.append((occurrence.schedule.id, minutes, asksBrowserAccess, missed))
        isSessionOrBreakOn = true
        return true
    }
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence) { headsUps.append(occurrence) }
    func dismissHeadsUp() {}
    func logSchedule(_ message: String) { logs.append(message) }
}

@MainActor
struct SchedulerTests {
    let host = FakeScheduleHost()
    let clock = TestClock()
    let scheduler: FocusScheduler

    init() {
        let clock = clock
        scheduler = FocusScheduler(host: host, now: { clock.now }, calendar: { newYork })
        clock.now = at("2026-03-09T08:00:00-04:00")
        host.schedules = [schedule("deep", goal: "Deep work")]
    }

    private func go(_ text: String, _ reason: FocusScheduler.Reason = .timer) -> Date? {
        clock.now = at(text)
        return scheduler.evaluate(reason)
    }

    @Test func aMinuteBeforeTheStartItShowsTheHeadsUpOnce() throws {
        // At 8:00 the next moment of interest is the heads-up, at 8:59.
        #expect(go("2026-03-09T08:00:00-04:00") == at("2026-03-09T08:59:00-04:00"))
        #expect(host.headsUps.isEmpty)

        // The heads-up, then the start a moment after its time.
        #expect(go("2026-03-09T08:59:00-04:00") == at("2026-03-09T09:00:00-04:00").addingTimeInterval(FocusScheduler.settle))
        #expect(host.headsUps.map(\.start) == [at("2026-03-09T09:00:00-04:00")])
        // Looking again in the same minute (a wake, say) does not show it twice.
        _ = go("2026-03-09T08:59:20-04:00", .wake)
        #expect(host.headsUps.count == 1)
        #expect(host.started.isEmpty)
    }

    @Test func atTheStartASessionBeginsWithoutAskingAnyBrowser() throws {
        _ = go("2026-03-09T09:00:01-04:00")
        let first = try #require(host.started.first)
        #expect(first.id == "deep")
        #expect(first.minutes == 180)
        #expect(!first.asks, "nobody clicked, so no macOS prompt")
        #expect(!first.missed)
        // Evaluating again changes nothing.
        _ = go("2026-03-09T09:00:03-04:00")
        #expect(host.started.count == 1)
    }

    @Test func theRequestCarriesTheSchedulesChoices() {
        var s = schedule("x", goal: "Deep work")
        s.categoryIDs = ["social", "messaging"]
        s.mode = .allow
        s.strict = true
        let request = s.request(minutes: 180)
        #expect(request == SessionRequest(goal: "Deep work", minutes: 180, categoryIDs: ["social", "messaging"],
                                          mode: .allow, strict: true, asksBrowserAccess: false, hasFixedEnd: true))
        #expect(schedule("y").request(minutes: 30).goal == "", "no goal is the empty goal, never a half-typed one")
        #expect(schedule("y").request(minutes: 30, asksBrowserAccess: true).asksBrowserAccess)
    }

    @Test func aSessionAlreadyOnSkipsTheRunAndSaysSo() {
        host.isSessionOrBreakOn = true
        _ = go("2026-03-09T08:59:00-04:00")
        #expect(host.headsUps.isEmpty, "no card for a start that will not happen")
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.isEmpty)
        #expect(host.logs.contains { $0.contains("already on") })
        // The session ends; the skipped run is not started late.
        host.isSessionOrBreakOn = false
        _ = go("2026-03-09T09:30:00-04:00", .wake)
        #expect(host.started.isEmpty)
    }

    @Test func aSessionTheUserEndedIsNotStartedAgain() {
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.count == 1)
        host.isSessionOrBreakOn = false      // ended early at 9:40
        _ = go("2026-03-09T10:30:00-04:00", .wake)
        _ = go("2026-03-09T10:31:00-04:00", .launch)
        #expect(host.started.count == 1)
    }

    @Test func aWakeInsideTheWindowMakesUpTheStart() throws {
        _ = go("2026-03-09T10:15:00-04:00", .wake)
        let first = try #require(host.started.first)
        #expect(first.minutes == 105)
        #expect(first.missed)
        #expect(!first.asks)
        #expect(host.logs.contains { $0.contains("late") })
    }

    @Test func aLaunchInsideTheWindowMakesUpTheStartToo() {
        _ = go("2026-03-09T11:00:00-04:00", .launch)
        #expect(host.started.map(\.minutes) == [60])
    }

    @Test func aWakeWithUnderFiveMinutesLeftSkipsItForGood() {
        _ = go("2026-03-09T11:56:00-04:00", .wake)
        #expect(host.started.isEmpty)
        #expect(host.scheduleHandled["deep"] == at("2026-03-09T09:00:00-04:00"))
        _ = go("2026-03-09T11:57:00-04:00", .timer)
        #expect(host.started.isEmpty, "and it is not tried again a minute later")
    }

    @Test func aWakeAfterTheWindowStartsNothingAndLooksToTomorrow() {
        let wake = go("2026-03-09T13:00:00-04:00", .wake)
        #expect(host.started.isEmpty)
        #expect(wake == at("2026-03-10T08:59:00-04:00"))
    }

    @Test func makingAScheduleInsideItsWindowStartsNothing() {
        // Nidus is open; the 9 to 12 schedule started its session at 9:00.
        _ = go("2026-03-09T09:00:02-04:00")
        host.isSessionOrBreakOn = false      // ended by 9:45
        // At 10:00 a schedule for 9:30 to 11:00 is made.
        host.schedules.append(schedule("fresh", (9, 30), (11, 0)))
        _ = go("2026-03-09T10:00:00-04:00", .edited)
        #expect(host.started.map(\.id) == ["deep"])
        // The next look, from any cause, does not start it either.
        _ = go("2026-03-09T10:05:00-04:00", .timer)
        _ = go("2026-03-09T10:06:00-04:00", .wake)
        #expect(host.started.map(\.id) == ["deep"])
        // It still runs another day.
        host.schedules.removeAll { $0.id == "deep" }
        _ = go("2026-03-10T09:30:02-04:00")
        #expect(host.started.map(\.id) == ["deep", "fresh"])
    }

    @Test func turningAScheduleOnOrMovingItInsideItsWindowStartsNothing() {
        host.schedules = [schedule("deep", isOn: false)]
        _ = go("2026-03-09T08:00:00-04:00")
        host.schedules[0].isOn = true
        _ = go("2026-03-09T10:00:00-04:00", .edited)
        #expect(host.started.isEmpty, "switched on at 10:00, inside 9 to 12")
        host.schedules[0].start = ScheduleTime(hour: 9, minute: 30)
        _ = go("2026-03-09T10:01:00-04:00", .edited)
        #expect(host.started.isEmpty)
    }

    @Test func anEditToAnotherScheduleDoesNotSwallowAStart() {
        host.schedules = [schedule("deep", goal: "Deep work"), schedule("evening", days: FocusSchedule.everyDay, (19, 0), (21, 0))]
        _ = go("2026-03-09T08:00:00-04:00")
        // A goal typed into the evening schedule, half a second after 9:00.
        host.schedules[1].goal = "Read"
        clock.now = at("2026-03-09T09:00:00-04:00").addingTimeInterval(0.5)
        _ = scheduler.evaluate(.edited)
        #expect(host.started.map(\.id) == ["deep"], "an edit to another schedule is not a reason to skip this one")
        #expect(host.started.first?.minutes == 180)
    }

    @Test func anEditDuringTheWakeDelayDoesNotSwallowTheMakeUp() {
        host.schedules = [schedule("deep"), schedule("evening", days: FocusSchedule.everyDay, (19, 0), (21, 0))]
        _ = go("2026-03-09T08:00:00-04:00")
        host.schedules[1].goal = "Read"
        _ = go("2026-03-09T10:15:00-04:00", .edited)
        #expect(host.started.map(\.id) == ["deep"])
        #expect(host.started.first?.minutes == 105)
        #expect(host.started.first?.missed == true)
    }

    @Test func onlyWhenItRunsCountsAsMovingASchedule() {
        let base = schedule()
        var edited = base
        edited.goal = "Deep work"
        edited.categoryIDs = ["video"]
        edited.strict = true
        edited.mode = .allow
        #expect(!edited.changesTiming(from: base))
        for change: (inout FocusSchedule) -> Void in [
            { $0.isOn = false }, { $0.weekdays = [monday] },
            { $0.start = ScheduleTime(hour: 8) }, { $0.end = ScheduleTime(hour: 13) },
        ] {
            var moved = base
            change(&moved)
            #expect(moved.changesTiming(from: base))
        }
    }

    @Test func overlappingRunsStartTheEarlierAndSkipTheOthers() {
        host.schedules = [schedule("late", (10, 0), (11, 0)), schedule("deep", (9, 0), (12, 0))]
        _ = go("2026-03-09T10:30:00-04:00", .wake)
        #expect(host.started.map(\.id) == ["deep"], "the one that began first, whatever the list order")
        #expect(host.started.first?.minutes == 90)
        #expect(host.logs.contains { $0.contains("already on") })
        // Neither starts when the session ends.
        host.isSessionOrBreakOn = false
        _ = go("2026-03-09T11:00:00-04:00", .timer)
        #expect(host.started.count == 1)
    }

    @Test func aRunThatStartsDuringASessionIsSkipped() {
        host.schedules = [schedule("deep", (9, 0), (12, 0)), schedule("late", (10, 0), (11, 0))]
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.map(\.id) == ["deep"])
        _ = go("2026-03-09T10:00:02-04:00")
        #expect(host.started.map(\.id) == ["deep"])
        #expect(host.logs.contains { $0.contains("already on") })
    }

    @Test func backToBackSchedulesBothRun() {
        host.schedules = [schedule("one", (9, 0), (10, 0)), schedule("two", (10, 0), (12, 0))]
        _ = go("2026-03-09T09:00:02-04:00")
        host.isSessionOrBreakOn = false      // the first finished at 10:00
        _ = go("2026-03-09T10:00:01-04:00")
        #expect(host.started.map(\.id) == ["one", "two"])
        #expect(host.started.last?.minutes == 120)
    }

    @Test func skippingTheHeadsUpSkipsTheRun() {
        _ = go("2026-03-09T08:59:00-04:00")
        let run = host.headsUps[0]
        clock.now = at("2026-03-09T08:59:10-04:00")
        scheduler.skip(run)
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.isEmpty)
        #expect(host.scheduleHandled["deep"] == run.start)
        // Tomorrow is not affected.
        _ = go("2026-03-10T09:00:02-04:00")
        #expect(host.started.count == 1)
    }

    @Test func startNowBeginsEarlyEndsWhereTheWindowEndsAndMayAsk() throws {
        _ = go("2026-03-09T08:59:00-04:00")
        let run = host.headsUps[0]
        clock.now = at("2026-03-09T08:59:20-04:00")
        scheduler.startNow(run)
        let first = try #require(host.started.first)
        #expect(first.minutes == 180, "three hours and forty seconds left; the odd seconds are dropped")
        #expect(first.asks, "it was a click")
        // The start time then passes without a second session.
        host.isSessionOrBreakOn = false
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.count == 1)
    }

    @Test func aScheduleWithNothingToBlockIsPassedOverNotRetried() {
        host.startSucceeds = false
        _ = go("2026-03-09T09:00:02-04:00")
        #expect(host.started.isEmpty)
        #expect(host.logs.contains { $0.contains("nothing to block") })
        host.startSucceeds = true
        _ = go("2026-03-09T09:00:30-04:00")
        #expect(host.started.isEmpty)
    }

    @Test func handledRunsOfDeletedSchedulesAreForgotten() {
        host.scheduleHandled = ["gone": at("2026-03-02T09:00:00-05:00"), "deep": at("2026-03-02T09:00:00-05:00")]
        _ = go("2026-03-09T08:00:00-04:00")
        #expect(Set(host.scheduleHandled.keys) == ["deep"])
    }

    @Test func withNothingOnThereIsNothingToWakeFor() {
        host.schedules = [schedule("deep", isOn: false)]
        #expect(go("2026-03-09T08:00:00-04:00") == nil)
    }

    @Test func aHeadsUpTooCloseToTheStartIsNotShown() {
        _ = go("2026-03-09T08:59:55-04:00", .launch)
        #expect(host.headsUps.isEmpty)
        _ = go("2026-03-09T08:59:40-04:00", .launch)
        #expect(host.headsUps.count == 1, "forty seconds is worth a card")
    }
}

// MARK: - No break after a fixed end

@MainActor
struct FixedEndTests {
    /// Runs the engine as the model does: when a session with a fixed end
    /// ends, its break is ended at once.
    /// `noteOffset` is how far the noted start is from the session's.
    private func finish(noteOffset: Double) -> (Harness, [SessionEvent]) {
        let h = Harness()
        h.engine.breakLength = 5 * minute
        let events = h.events
        h.engine.start(plan(25))
        let started = h.engine.session!.startedAt.timeIntervalSince1970
        h.engine.onEvent = { [engine = h.engine] event in
            events.all.append(event)
            if case .ended(_, let final) = event, NidusModel.isFixedEnd(final, recorded: started + noteOffset) {
                engine.endBreak()
            }
        }
        h.clock.advance(25 * minute)
        h.engine.tick()
        return (h, events.all)
    }

    @Test func aFixedEndSessionIsNotFollowedByABreak() {
        let (h, events) = finish(noteOffset: 0)
        #expect(!h.engine.isOnBreak, "a break would start the same length again, past the time it was meant to stop at")
        #expect(h.engine.session == nil)
        #expect(events.count == 3 && events.last == .breakEnded)
    }

    @Test func anyOtherSessionStillEarnsItsBreak() {
        // The note is for a different session.
        let (h, events) = finish(noteOffset: 3600)
        #expect(h.engine.isOnBreak)
        #expect(events.last != .breakEnded)
    }

    @Test func theNoteMatchesToTheSecond() {
        let h = Harness()
        h.engine.start(plan(25))
        let final = h.engine.session!
        let started = final.startedAt.timeIntervalSince1970
        #expect(NidusModel.isFixedEnd(final, recorded: started))
        #expect(NidusModel.isFixedEnd(final, recorded: started + 0.4), "a session file that keeps whole seconds")
        #expect(!NidusModel.isFixedEnd(final, recorded: started + 5))
        #expect(!NidusModel.isFixedEnd(final, recorded: 0), "nothing noted")
    }
}
