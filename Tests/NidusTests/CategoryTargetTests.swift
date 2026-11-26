//
//  CategoryTargetTests.swift
//  NidusTests
//
//  Daily category targets: tolerant decoding, the round trip, the colour fill
//  keeping them, the progress arithmetic, and the widget snapshot with and
//  without one.
//

import Foundation
import Testing
@testable import Nidus

@Suite("Category targets")
struct CategoryTargetTests {
    private func category(_ extra: String) throws -> FocusCategory {
        let json = """
        {"id":"a","name":"Reading","symbol":"book","apps":[],"websites":[]\(extra)}
        """
        return try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func aValidTargetDecodes() throws {
        #expect(try category(",\"dailyTarget\":3600").dailyTarget == 3600)
        #expect(try category(",\"dailyTarget\":86400").dailyTarget == 86_400)
        #expect(try category(",\"dailyTarget\":900.5").dailyTarget == 900.5)
    }

    @Test func anythingElseIsNoTarget() throws {
        for bad in ["\"1h\"", "-5", "0", "86401", "1e12", "null", "true", "[1]", "{}"] {
            #expect(try category(",\"dailyTarget\":\(bad)").dailyTarget == nil, "\(bad)")
        }
    }

    @Test func aFileFromBeforeTargetsLoadsUnchanged() throws {
        let old = try category(",\"role\":\"work\",\"color\":3")
        #expect(old.dailyTarget == nil)
        #expect(old.role == .work)
        #expect(old.color == 3)
    }

    @Test func aBadTargetLosesOnlyItself() throws {
        let value = try category(",\"color\":2,\"dailyTarget\":\"x\",\"role\":\"neutral\"")
        #expect(value.dailyTarget == nil)
        #expect(value.color == 2)
        #expect(value.role == .neutral)
    }

    @Test func roundTripsAndIsWrittenOnlyWhenSet() throws {
        var value = try category("")
        let without = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!without.contains("dailyTarget"))
        value.dailyTarget = 5400
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("dailyTarget"))
        #expect(try JSONDecoder().decode(FocusCategory.self, from: data) == value)
    }

    @Test func theWorkGroupCanHaveOne() throws {
        var work = FocusCategory.workSeed
        work.dailyTarget = 4 * 3600
        let data = try JSONEncoder().encode(work)
        let back = try JSONDecoder().decode(FocusCategory.self, from: data)
        #expect(back.dailyTarget == TimeInterval(4 * 3600))
        #expect(back.role == .work)
    }

    @Test func fillingColoursKeepsTheTarget() throws {
        var a = try category("")
        a.dailyTarget = 1800
        var b = try category("")
        b.id = "b"
        let filled = CategoryPalette.fillingColors(of: [a, b], keeping: [a])
        #expect(filled.first { $0.id == "a" }?.dailyTarget == 1800)
        #expect(filled.first { $0.id == "b" }?.dailyTarget == nil)
    }

    // MARK: Choices

    @Test func choicesAreEveryFifteenMinutesToTwelveHours() {
        let steps = CategoryTarget.choices()
        #expect(steps.first == 900)
        #expect(steps.last == 43_200)
        #expect(steps.count == 48)
    }

    @Test func aSavedOffGridTargetIsStillOffered() {
        #expect(CategoryTarget.choices(including: 6000).contains(6000))
        #expect(CategoryTarget.choices(including: 6000) == CategoryTarget.choices(including: 6000).sorted())
        #expect(CategoryTarget.choices(including: 3600).count == 48)
        #expect(CategoryTarget.choices(including: -1).count == 48)
    }

    // MARK: Progress

    @Test func fractionClampsAndMetAgreesWithTheWords() {
        #expect(CategoryTarget.fraction(done: 0, target: 3600) == 0)
        #expect(CategoryTarget.fraction(done: 1800, target: 3600) == 0.5)
        #expect(CategoryTarget.fraction(done: 9000, target: 3600) == 1)
        #expect(CategoryTarget.fraction(done: -5, target: 3600) == 0)
        #expect(CategoryTarget.fraction(done: 10, target: 0) == 0)
        #expect(CategoryTarget.isMet(done: 3600, target: 3600))
        // 3 h 59 m 40 s reads "4 hr" and so is met.
        #expect(CategoryTarget.isMet(done: 4 * 3600 - 20, target: 4 * 3600))
        #expect(!CategoryTarget.isMet(done: 4 * 3600 - 40, target: 4 * 3600))
        #expect(!CategoryTarget.isMet(done: 100, target: 0))
    }

    @Test func elapsedDaysCountsTheDaysSoFar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        let week = DateInterval(start: monday, duration: 7 * 86_400)
        let wednesdayNoon = monday.addingTimeInterval(2 * 86_400 + 12 * 3600)
        #expect(CategoryTarget.elapsedDays(in: week, now: wednesdayNoon, calendar: calendar) == 3)
        #expect(CategoryTarget.elapsedDays(in: week, now: monday.addingTimeInterval(30 * 86_400), calendar: calendar) == 7)
        #expect(CategoryTarget.elapsedDays(in: week, now: monday.addingTimeInterval(-86_400), calendar: calendar) == 1)
    }

    @Test func anAverageDaySkipsDaysWithNothingTracked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        let week = DateInterval(start: monday, duration: 7 * 86_400)
        let day = { (n: Int) in monday.addingTimeInterval(Double(n) * 86_400) }
        let fridayNoon = day(4).addingTimeInterval(12 * 3600)
        // Tracked Monday, Wednesday and Friday (Friday at 3 pm, any hour counts);
        // Sunday is still ahead and last Sunday is outside the week.
        let tracked: Set<Date> = [day(0), day(2), day(4).addingTimeInterval(15 * 3600), day(6), day(-1)]
        #expect(CategoryTarget.trackedDays(tracked, in: week, now: fridayNoon, calendar: calendar) == 3)
        #expect(CategoryTarget.trackedDays(tracked, in: week, now: day(30), calendar: calendar) == 4)
        #expect(CategoryTarget.trackedDays([], in: week, now: fridayNoon, calendar: calendar) == 1)

        // 6 h of Work over three tracked days of five is 2 h a day, not 1 h 12 m.
        var work = FocusCategory.workSeed
        work.dailyTarget = 2 * 3600
        let categorizer = ActivityCategorizer(categories: [], work: work)
        let total = ActivityCategoryTotal(id: ActivityCategorizer.workID, name: "Work", symbol: "briefcase",
                                          seconds: 6 * 3600, share: 1)
        let days = CategoryTarget.trackedDays(tracked, in: week, now: fridayNoon, calendar: calendar)
        let row = CategoryTargetProgress.rows(totals: [total], categorizer: categorizer, days: days).first
        #expect(row?.done == TimeInterval(2 * 3600))
        #expect(row?.isMet == true)
        #expect(row?.isAverage == true)
    }

    @Test func totalsKnowWhichDaysHadTime() {
        let monday = Date(timeIntervalSinceReferenceDate: 794_102_400)
        let rows: [(day: Date, row: FocusActivity)] = [
            (monday, FocusActivity(appID: "a", appName: "A", seconds: 600)),
            (monday.addingTimeInterval(2 * 86_400), FocusActivity(appID: "b", appName: "B", seconds: 60)),
            (monday.addingTimeInterval(86_400), FocusActivity(appID: "c", appName: "C", seconds: 0)),
        ]
        let totals = ActivityTotals(rows: rows, focused: 0)
        #expect(totals.trackedDays == [monday, monday.addingTimeInterval(2 * 86_400)])
    }

    @Test func rowsListEveryTargetedGroupWorkFirstEvenWithNoTime() {
        var work = FocusCategory.workSeed
        work.dailyTarget = 4 * 3600
        var reading = FocusCategory(id: "reading", name: "Reading", symbol: "book", apps: [], websites: [])
        reading.dailyTarget = 3600
        let plain = FocusCategory(id: "plain", name: "Plain", symbol: "circle", apps: [], websites: [])
        let categorizer = ActivityCategorizer(categories: [plain, reading], work: work)
        let totals = [ActivityCategoryTotal(id: "work", name: "Work", symbol: "briefcase", seconds: 2 * 3600, share: 1)]
        let rows = CategoryTargetProgress.rows(totals: totals, categorizer: categorizer)
        #expect(rows.map(\.id) == ["work", "reading"])
        #expect(rows[0].fraction == 0.5)
        #expect(rows[1].done == 0)
        #expect(!rows[1].isMet)
        #expect(rows[0].tint == ActivityTint.work)
        #expect(rows[0].text == "Work 2 hr of 4 hr")
    }

    @Test func aWeekReadsAsTheAverageDay() {
        var work = FocusCategory.workSeed
        work.dailyTarget = 4 * 3600
        let categorizer = ActivityCategorizer(categories: [], work: work)
        let totals = [ActivityCategoryTotal(id: "work", name: "Work", symbol: "briefcase", seconds: 14 * 3600, share: 1)]
        let row = CategoryTargetProgress.rows(totals: totals, categorizer: categorizer, days: 7)[0]
        #expect(row.done == 2 * 3600)
        #expect(row.isAverage)
        #expect(row.text == "Work 2 hr a day of 4 hr")
    }

    @Test func noTargetsMeansNoRows() {
        let categorizer = ActivityCategorizer(categories: [], work: FocusCategory.workSeed)
        #expect(CategoryTargetProgress.rows(totals: [], categorizer: categorizer).isEmpty)
        #expect(ActivityTodaySummary.target([:], categorizer: categorizer) == nil)
    }

    // MARK: The chart

    @Test func theScaleGrowsToHoldTheTarget() {
        #expect(ActivityDailyBars.ceiling(totals: [3600, 7200], target: nil) == 7200)
        #expect(ActivityDailyBars.ceiling(totals: [3600, 7200], target: 4 * 3600) == 4 * 3600)
        #expect(ActivityDailyBars.ceiling(totals: [3600], target: 0) == 3600)
        #expect(ActivityDailyBars.ceiling(totals: [], target: nil) == 1)
    }

    @Test func aGridlineUnderTheTargetIsLeftOut() {
        let ceiling: TimeInterval = 4 * 3600
        #expect(ActivityDailyBars.gridlines(ceiling: ceiling).contains(ceiling))
        #expect(!ActivityDailyBars.gridlines(ceiling: ceiling, target: ceiling).contains(ceiling))
        #expect(ActivityDailyBars.gridlines(ceiling: ceiling, target: nil) == ActivityDailyBars.gridlines(ceiling: ceiling))
    }

    // MARK: The widget

    private func snapshot(_ json: String) throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
    }

    @Test func aSnapshotWithoutATargetStillDecodes() throws {
        let value = try snapshot("""
        {"version":1,"today":{"day":"2026-03-10","work":600,"top":[{"name":"Work","minutes":10,"tint":-2}]}}
        """)
        #expect(value.today?.work == 600)
        #expect(value.today?.target == nil)
    }

    @Test func aTargetDecodesAndRoundTrips() throws {
        let value = try snapshot("""
        {"today":{"day":"2026-03-10","work":600,"target":{"name":"Work","seconds":7200,"target":14400,"tint":-2}}}
        """)
        let target = try #require(value.today?.target)
        #expect(target.name == "Work")
        #expect(target.fraction == 0.5)
        #expect(!target.isMet)
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(value))
        #expect(back == value)
    }

    @Test func aBadTargetIsDroppedAndTheDayKept() throws {
        for bad in ["{\"name\":\"W\",\"seconds\":10,\"target\":0,\"tint\":1}",
                    "{\"name\":\"W\",\"seconds\":10,\"target\":-60,\"tint\":1}",
                    "{\"name\":\"W\",\"seconds\":10,\"target\":999999,\"tint\":1}",
                    "{\"seconds\":10,\"target\":3600}", "\"x\"", "5"] {
            let value = try snapshot("{\"today\":{\"day\":\"2026-03-10\",\"work\":600,\"target\":\(bad)}}")
            #expect(value.today?.work == 600, "\(bad)")
            #expect(value.today?.target == nil, "\(bad)")
        }
    }

    @Test func theWidgetsArithmeticMatchesTheApps() {
        for (done, goal) in [(0, 3600), (1800, 3600), (3580, 3600), (3500, 3600), (9000, 3600), (30, 40)] {
            let target = WidgetToday.Target(name: "W", seconds: done, target: goal, tint: 0)
            #expect(target.fraction == CategoryTarget.fraction(done: TimeInterval(done), target: TimeInterval(goal)), "\(done)/\(goal)")
            #expect(target.isMet == CategoryTarget.isMet(done: TimeInterval(done), target: TimeInterval(goal)), "\(done)/\(goal)")
        }
    }

    @Test func todaysSummaryNamesTheFirstTargetedGroup() {
        var work = FocusCategory.workSeed
        work.dailyTarget = 4 * 3600
        let categorizer = ActivityCategorizer(categories: [], work: work)
        let target = ActivityTodaySummary.target(["work": 5400], categorizer: categorizer)
        #expect(target == WidgetToday.Target(name: "Work", seconds: 5400, target: 14_400, tint: ActivityTint.work))
        #expect(ActivityTodaySummary.target([:], categorizer: categorizer)?.seconds == 0)
    }
}
