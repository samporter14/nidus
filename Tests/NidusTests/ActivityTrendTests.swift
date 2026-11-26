import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct ActivityTrendTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }
    private func key(_ date: Date) -> String { ActivityDayLog.key(for: date, calendar: calendar) }
    private var categorizer: ActivityCategorizer {
        let social = FocusCategory(id: "social", name: "Social", symbol: "circle", apps: [], websites: ["reddit.com"])
        let chat = FocusCategory(id: "chat", name: "Messaging", symbol: "circle", apps: [], websites: [])
        return ActivityCategorizer(categories: [social, chat], work: FocusCategory.workSeed)
    }
    /// `days` days ending on `last`, each with the same hour of work.
    private func history(days: Int, ending last: Date, extra: [String: TimeInterval] = [:]) -> [String: [String: TimeInterval]] {
        var result: [String: [String: TimeInterval]] = [:]
        for back in 0..<days {
            let day = calendar.date(byAdding: .day, value: -back, to: last)!
            result[key(day)] = ["work": 3600].merging(extra) { $0 + $1 }
        }
        return result
    }

    @Test func monthIsThirtyDistinctConsecutiveDaysAcrossAClockChange() {
        // The clocks go back on 1 Nov 2026.
        let end = date(11, 8)
        let trend = ActivityTrend(span: .month, ending: end, byDay: history(days: 40, ending: end), categorizer: categorizer, calendar: calendar)
        let keys = trend.buckets.flatMap(\.keys)
        #expect(trend.buckets.count == 30)
        #expect(Set(keys).count == 30)
        #expect(keys == keys.sorted())
        #expect(keys.contains("2026-11-01"))
        #expect(keys.last == "2026-11-08")
        #expect(trend.buckets.allSatisfy { $0.seconds == 3600 })
    }

    @Test func quarterWeeksStartOnTheCalendarAndHoldSevenDaysAcrossAClockChange() {
        let end = date(11, 8) // a Sunday: the week of 2 Nov is whole
        let trend = ActivityTrend(span: .quarter, ending: end, byDay: history(days: 100, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(trend.buckets.count == 13)
        #expect(trend.buckets.allSatisfy { $0.keys.count == 7 && !$0.isPartial })
        #expect(Set(trend.buckets.flatMap(\.keys)).count == 91)
        #expect(trend.buckets.allSatisfy { calendar.component(.weekday, from: $0.start) == 2 })
        #expect(trend.buckets.allSatisfy { $0.seconds == 7 * 3600 })
        // The week holding the change still starts at midnight on Monday.
        #expect(trend.buckets.contains { key($0.start) == "2026-10-26" })
    }

    @Test func aWeekStillGoingIsPartial() {
        let end = date(11, 11) // a Wednesday
        let trend = ActivityTrend(span: .quarter, ending: end, byDay: history(days: 100, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(trend.buckets.last?.keys.count == 3)
        #expect(trend.buckets.last?.isPartial == true)
        #expect(trend.buckets.dropLast().allSatisfy { !$0.isPartial })
        #expect(ActivityTrend.keys(ending: end, calendar: calendar).count == 12 * 7 + 3)
    }

    @Test func seriesFollowTheCategorizersOrderWithItsTints() {
        let end = date(11, 8)
        let byDay = history(days: 10, ending: end, extra: ["chat": 600, "uncategorized": 60, "social": 300])
        let trend = ActivityTrend(span: .month, ending: end, byDay: byDay, categorizer: categorizer, calendar: calendar)
        #expect(trend.series.map(\.id) == ["work", "social", "chat", "uncategorized"])
        for series in trend.series { #expect(series.tint == categorizer.tint(of: series.id)) }
        #expect(trend.series.allSatisfy { $0.values.count == 30 })
    }

    @Test func missingDaysCountAsZero() {
        let end = date(11, 8)
        var byDay = history(days: 30, ending: end)
        byDay[key(date(11, 5))] = nil
        let trend = ActivityTrend(span: .month, ending: end, byDay: byDay, categorizer: categorizer, calendar: calendar)
        let index = trend.buckets.firstIndex { $0.keys == ["2026-11-05"] }!
        #expect(trend.series[0].values[index] == 0)
        #expect(!trend.buckets[index].hasData)
        #expect(trend.series[0].values[index - 1] == 3600)
        #expect(trend.keptCount == 30)
    }

    @Test func shortHistoryCountsOnlyTheBucketsKept() {
        let end = date(11, 8)
        let month = ActivityTrend(span: .month, ending: end, byDay: history(days: 10, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(month.keptCount == 10)
        #expect(month.firstDataIndex == 20)
        #expect(month.shortNote == "Only 10 days kept so far")
        let quarter = ActivityTrend(span: .quarter, ending: end, byDay: history(days: 24, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(quarter.keptCount == 4)
        #expect(quarter.shortNote == "Only 4 weeks kept so far")
        let full = ActivityTrend(span: .month, ending: end, byDay: history(days: 30, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(full.shortNote == nil)
    }

    @Test func nothingKeptIsEmpty() {
        let trend = ActivityTrend(span: .quarter, ending: date(11, 8), byDay: [:], categorizer: categorizer, calendar: calendar)
        #expect(trend.isEmpty)
        #expect(trend.series.isEmpty)
        #expect(trend.keptCount == 0)
        #expect(trend.shortNote == nil)
        #expect(trend.buckets.count == 13)
        #expect(trend.buckets.allSatisfy { !$0.hasData })
        #expect(trend.peak == 0)
    }

    @Test func bothSpansComeFromOneLoad() {
        let end = date(11, 8)
        let trends = ActivityTrends(ending: end, byDay: history(days: 100, ending: end), categorizer: categorizer, calendar: calendar)
        #expect(trends[.month].buckets.count == 30)
        #expect(trends[.quarter].buckets.count == 13)
        let wanted = Set(ActivityTrends.keys(ending: end, calendar: calendar))
        #expect(Set(trends[.month].buckets.flatMap(\.keys)).isSubset(of: wanted))
    }
}
