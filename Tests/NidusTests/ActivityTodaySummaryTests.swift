//
//  ActivityTodaySummaryTests.swift
//  NidusTests
//
//  Today for the Nidus Today widget and the Shortcuts actions: the split, the
//  bands, when the summary is worked out again, and what widget.json carries.
//

import Foundation
import Testing
@testable import Nidus

@Suite("Today's activity summary")
struct ActivityTodaySummaryTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }()
    private var calendar: Calendar { Self.calendar }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }
    private var key: String { ActivityDayLog.key(for: day, calendar: calendar) }

    private var categorizer: ActivityCategorizer {
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "work.app", name: "Work")]
        var social = FocusCategory.workSeed
        social.id = "social"
        social.apps = [BlockedApp(bundleID: "social.app", name: "Social")]
        return ActivityCategorizer(categories: [social], work: work)
    }

    private func stretch(_ app: String, from start: TimeInterval, to end: TimeInterval) -> FocusActivitySegment {
        FocusActivitySegment(start: day.addingTimeInterval(start * 60), end: day.addingTimeInterval(end * 60), appID: app, appName: app)
    }

    private func log(_ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: key)
        log.stretches = stretches
        return log
    }

    private func build(_ stretches: [FocusActivitySegment]) -> WidgetToday {
        ActivityTodaySummary.build(log: log(stretches), categorizer: categorizer, calendar: calendar)
    }

    /// Work and distracting in turn, each `minutes` long, with no gaps.
    private func busyDay(minutes: TimeInterval, count: Int) -> [FocusActivitySegment] {
        (0..<count).map { index in
            let start = minutes * TimeInterval(index)
            return stretch(index.isMultiple(of: 2) ? "work.app" : "social.app", from: start, to: start + minutes)
        }
    }

    // MARK: The split

    @Test func workIsTheWorkGroupDistractingAnyOtherCategoryOtherUncategorized() {
        let today = build([stretch("work.app", from: 540, to: 600),
                           stretch("social.app", from: 600, to: 610),
                           stretch("unknown.app", from: 610, to: 615)])
        #expect(today.day == key)
        #expect(today.work == 3600)
        #expect(today.distracting == 600)
        #expect(today.other == 300)
        #expect(today.total == 4500)
    }

    @Test func theSplitIsTheHourGrids() {
        var stretches = busyDay(minutes: 7, count: 40)
        stretches.append(stretch("unknown.app", from: 600, to: 633))
        let today = build(stretches)
        let grid = ActivityHeatmap(stretches: stretches, categorizer: categorizer, calendar: calendar)
        #expect(Double(today.work) == grid.cells.map(\.work).reduce(0, +))
        #expect(Double(today.distracting) == grid.cells.map(\.distraction).reduce(0, +))
        #expect(Double(today.other) == grid.cells.map(\.other).reduce(0, +))
    }

    @Test func aDayWithNothingHasNoBands() {
        let today = build([])
        #expect(today.total == 0)
        #expect(today.bands.isEmpty)
    }

    // MARK: Bands

    @Test func bandsAreClassifiedFirstSoTwoAppsOfOneKindAreOneBand() {
        var other = FocusCategory.workSeed
        other.id = "video"
        other.apps = [BlockedApp(bundleID: "video.app", name: "Video")]
        var social = other
        social.id = "social"
        social.apps = [BlockedApp(bundleID: "social.app", name: "Social")]
        let categorizer = ActivityCategorizer(categories: [social, other], work: FocusCategory.workSeed)
        let today = ActivityTodaySummary.build(log: log([stretch("social.app", from: 60, to: 90), stretch("video.app", from: 90, to: 120)]),
                                               categorizer: categorizer, calendar: calendar)
        #expect(today.bands == [WidgetToday.Band(startMinute: 60, endMinute: 120, kind: .distracting)])
    }

    @Test func aBandSpansASmallGapAndStopsAtALongOne() {
        let today = build([stretch("work.app", from: 60, to: 90), stretch("work.app", from: 100, to: 120),
                           stretch("work.app", from: 200, to: 230)])
        #expect(today.bands.map(\.startMinute) == [60, 200])
        #expect(today.bands.map(\.endMinute) == [120, 230])
    }

    @Test func aBandCoversThePartialMinutesAtEachEnd() {
        let today = build([stretch("work.app", from: 60.5, to: 61.25)])
        #expect(today.bands == [WidgetToday.Band(startMinute: 60, endMinute: 62, kind: .work)])
    }

    @Test func aBusyDayStaysWithinTheLimitAndItsSecondsStayExact() {
        // The wall a day's file can reach: alternating, so nothing joins.
        let stretches = busyDay(minutes: 1440.0 / Double(ActivityDayLog.stretchLimit), count: ActivityDayLog.stretchLimit)
        let today = build(stretches)
        #expect(!today.bands.isEmpty)
        #expect(today.bands.count <= WidgetToday.bandLimit)
        #expect(today.total == 86_400)
        #expect(today.bands.allSatisfy { $0.startMinute >= 0 && $0.endMinute > $0.startMinute && $0.endMinute <= 1440 })
        #expect(zip(today.bands, today.bands.dropFirst()).allSatisfy { $0.startMinute <= $1.startMinute })
    }

    @Test func isolatedMomentsAreStillCappedAndAllStillCounted() {
        // Too far apart for any to join: the shortest fall off the drawing.
        let stretches = (0..<40).map { stretch("work.app", from: Double($0) * 30, to: Double($0) * 30 + 1 + Double($0) / 10) }
        let today = build(stretches)
        #expect(today.bands.count == WidgetToday.bandLimit)
        #expect(today.work == Int(stretches.map(\.seconds).reduce(0, +).rounded()))
        // The latest of them are the longest.
        #expect(today.bands.last?.startMinute == 39 * 30)
    }

    @Test func aFewBandsAreLeftAlone() {
        let today = build([stretch("work.app", from: 60, to: 90), stretch("social.app", from: 90, to: 90.5),
                           stretch("work.app", from: 90.5, to: 120)])
        #expect(today.bands.map(\.kind) == [.work, .distracting, .work])
    }

    @Test func aDayOf25HoursReachesItsLastHour() {
        // Clocks go back on November 1 in Detroit.
        let long = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        var log = ActivityDayLog(day: ActivityDayLog.key(for: long, calendar: calendar))
        log.stretches = [FocusActivitySegment(start: long.addingTimeInterval(24 * 3600), end: long.addingTimeInterval(24.5 * 3600),
                                              appID: "work.app", appName: "Work")]
        let today = ActivityTodaySummary.build(log: log, categorizer: categorizer, calendar: calendar)
        #expect(today.bands == [WidgetToday.Band(startMinute: 1440, endMinute: 1470, kind: .work)])
    }

    // MARK: When it's worked out

    private let source = WidgetTodayThrottle.Source(version: 1, excluded: [])

    private func written(at date: Date) -> WidgetTodayThrottle {
        var throttle = WidgetTodayThrottle()
        throttle.source = source
        throttle.didWrite(day: "2026-03-10", at: date)
        return throttle
    }

    @Test func theFirstIsAlwaysDue() {
        #expect(WidgetTodayThrottle().isDue(day: "2026-03-10", source: source, now: day))
    }

    @Test func nothingIsDueInsideFifteenMinutes() {
        let throttle = written(at: day)
        #expect(!throttle.isDue(day: "2026-03-10", source: source, now: day))
        #expect(!throttle.isDue(day: "2026-03-10", source: source, now: day.addingTimeInterval(15 * 60 - 1)))
        #expect(throttle.isDue(day: "2026-03-10", source: source, now: day.addingTimeInterval(15 * 60)))
    }

    @Test func aNewDayIsDueAtOnce() {
        #expect(written(at: day).isDue(day: "2026-03-11", source: source, now: day.addingTimeInterval(60)))
    }

    @Test func aClearedRecordOrAnExcludedAppIsDueAtOnce() {
        let throttle = written(at: day)
        let later = day.addingTimeInterval(60)
        #expect(throttle.isDue(day: "2026-03-10", source: .init(version: 2, excluded: []), now: later))
        #expect(throttle.isDue(day: "2026-03-10", source: .init(version: 1, excluded: ["work.app"]), now: later))
    }

    @Test func aClockSetBackDoesntHoldTheNextOneOff() {
        #expect(written(at: day).isDue(day: "2026-03-10", source: source, now: day.addingTimeInterval(-3600)))
    }

    @Test func onlyTodayChangingIsToldApartFromAnythingElse() {
        let old = WidgetSnapshot(today: WidgetToday(day: key, work: 60))
        var new = old
        new.today?.work = 120
        #expect(new.differsOnlyInToday(from: old))
        new.state = .focusing
        #expect(!new.differsOnlyInToday(from: old))
        #expect(!old.differsOnlyInToday(from: old))
        #expect(!old.differsOnlyInToday(from: nil))
        #expect(WidgetSnapshot(today: nil).differsOnlyInToday(from: old))
    }

    @MainActor @Test func theSnapshotOnlyReadsWhatIsKept() async {
        // publishWidget reads this every second, so it must not build anything.
        let model = NidusModel()
        #expect(model.widgetSnapshot.today == nil)
        let kept = WidgetToday(day: key, work: 60)
        model.widgetToday = kept
        #expect(model.widgetSnapshot.today == kept)
    }

    @MainActor @Test func withoutAControllerNothingIsCounted() async {
        let model = NidusModel()
        model.refreshWidgetToday(now: day)
        #expect(model.widgetTodayTask == nil)
        let today = await model.activityToday(now: day)
        #expect(today.day == WidgetToday.key(for: day))
        #expect(today.total == 0)
    }

    // MARK: widget.json

    /// As much as the widget can be given: every setup, every band, the
    /// longest times a day holds, and setups with long names.
    private var largest: WidgetSnapshot {
        let setups = (0..<WidgetSnapshot.setupLimit).map { _ in
            WidgetSnapshot.Setup(id: UUID().uuidString, name: String(repeating: "m", count: 80), symbol: "brain.head.profile.fill")
        }
        let bands = (0..<WidgetToday.bandLimit).map {
            WidgetToday.Band(startMinute: 1380 + $0, endMinute: 1400 + $0, kind: .distracting)
        }
        let today = WidgetToday(day: "2026-03-10", work: 86_400, distracting: 86_400, other: 86_400, bands: bands)
        return WidgetSnapshot(state: .focusing, goal: String(repeating: "g", count: 120), endsAt: 1_800_000_000, strict: true,
                              setups: setups, today: today)
    }

    @Test func theFileStaysSmallAtItsLargest() throws {
        // The widget reads this at every reload. Past this, something unbounded got in.
        let snapshot = largest
        let data = try JSONEncoder().encode(snapshot)
        #expect(data.count < 4096)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == snapshot)
    }

    @Test func aFileFromBeforeTodayStillDecodes() throws {
        let old = #"{"version":1,"state":"idle","goal":"","strict":false,"setups":[{"id":"a","name":"Deep","symbol":"scope"}]}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.today == nil)
        #expect(snapshot.setups.map(\.name) == ["Deep"])
    }

    @Test func anEmptyTodayLeavesTheFileAsItWas() throws {
        let data = try JSONEncoder().encode(WidgetSnapshot())
        #expect(!String(decoding: data, as: UTF8.self).contains("today"))
    }

    @Test func theKeyIsTheDayRecordsOwn() {
        for offset in [0, 1, 40, 300] {
            let date = day.addingTimeInterval(Double(offset) * 86_400 + 3600)
            #expect(WidgetToday.key(for: date, calendar: calendar) == ActivityDayLog.key(for: date, calendar: calendar))
        }
    }

    @Test func todayIsShownOnlyOnItsOwnDay() {
        let snapshot = WidgetSnapshot(today: WidgetToday(day: key, work: 60))
        #expect(snapshot.today(at: day.addingTimeInterval(23 * 3600), calendar: calendar)?.work == 60)
        #expect(snapshot.today(at: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar) == nil)
        #expect(snapshot.today(at: day.addingTimeInterval(-1), calendar: calendar) == nil)
    }

    @Test func aDayWithNothingCountedShowsAsEmpty() {
        #expect(WidgetSnapshot(today: WidgetToday(day: key)).today(at: day, calendar: calendar) == nil)
        #expect(WidgetSnapshot().today(at: day, calendar: calendar) == nil)
    }

    // MARK: Said aloud

    @Test func theSentenceNamesWhatWasCounted() {
        let today = WidgetToday(day: key, work: 5400, distracting: 1200, other: 3600)
        #expect(ActivityTodaySummary.sentence(today, tracking: true)
                == "Today so far: 1 hour 30 minutes of Work, 20 minutes distracting, 1 hour of everything else.")
    }

    @Test func theSentenceLeavesOutWhatIsnt() {
        #expect(ActivityTodaySummary.sentence(WidgetToday(day: key, other: 600), tracking: true)
                == "Today so far: 10 minutes of everything else.")
        #expect(ActivityTodaySummary.sentence(WidgetToday(day: key, other: 20), tracking: true) == "Under a minute counted today.")
    }

    @Test func anEmptyDaySaysWhy() {
        let empty = WidgetToday(day: key)
        #expect(ActivityTodaySummary.sentence(empty, tracking: true) == "Nidus hasn't counted anything today.")
        #expect(ActivityTodaySummary.sentence(empty, tracking: false).contains("off"))
    }

    @Test func workInMinutesSaysSo() {
        let today = WidgetToday(day: key, work: 5400)
        #expect(ActivityTodaySummary.workMinutes(today) == 90)
        #expect(ActivityTodaySummary.workSentence(today, tracking: true, workHasItems: true) == "1 hour 30 minutes of Work today.")
    }

    @Test func anEmptyWorkGroupIsSaidPlainly() {
        let today = WidgetToday(day: key, other: 3600)
        #expect(ActivityTodaySummary.workMinutes(today) == 0)
        #expect(ActivityTodaySummary.workSentence(today, tracking: true, workHasItems: false).hasPrefix("Your Work group is empty"))
    }

    @Test func noWorkYetIsNotAnEmptyGroup() {
        let today = WidgetToday(day: key, other: 3600)
        #expect(ActivityTodaySummary.workSentence(today, tracking: true, workHasItems: true) == "No Work time yet today.")
        #expect(ActivityTodaySummary.workSentence(today, tracking: false, workHasItems: true).contains("off"))
    }

    @Test func secondsOfWorkAreNotNothing() {
        let today = WidgetToday(day: key, work: 20)
        #expect(ActivityTodaySummary.workMinutes(today) == 0)
        #expect(ActivityTodaySummary.workSentence(today, tracking: true, workHasItems: true) == "Under a minute of Work today.")
    }
}
