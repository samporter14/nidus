import Foundation
import Testing
@testable import Nidus

@Suite struct ActivityComparisonTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-11-17 is a Tuesday.
    private var tuesday: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))! }

    private func days(back weeks: Int, extra: Int = 0) -> Date {
        calendar.date(byAdding: .day, value: -7 * weeks + extra, to: tuesday)!
    }

    private func format(_ seconds: TimeInterval) -> String { "\(Int(seconds / 60)) min" }

    @Test func medianOfOddAndEvenCounts() {
        #expect(ActivityComparison.median([300, 100, 200]) == 200)
        #expect(ActivityComparison.median([400, 100, 200, 300]) == 250)
        #expect(ActivityComparison.median([90]) == 90)
        #expect(ActivityComparison.median([]) == nil)
    }

    @Test func tooLittleHistoryHasNoLine() {
        #expect(ActivityComparison.phrase(value: 7200, history: [3600, 3600], weekday: "Tuesday", format: format) == nil)
        #expect(ActivityComparison.phrase(value: 7200, history: [], weekday: "Tuesday", format: format) == nil)
        #expect(ActivityComparison.phrase(value: 7200, history: [3600, 3600, 3600], weekday: "Tuesday", format: format) != nil)
    }

    @Test func moreLessAndAboutPhrasing() {
        let usual: [TimeInterval] = [3600, 3600, 7200]  // median 3600
        #expect(ActivityComparison.phrase(value: 6000, history: usual, weekday: "Tuesday", format: format)
                == "40 min more than your usual Tuesday")
        #expect(ActivityComparison.phrase(value: 1200, history: usual, weekday: "Tuesday", format: format)
                == "40 min less than your usual Tuesday")
        #expect(ActivityComparison.phrase(value: 3900, history: usual, weekday: "Tuesday", format: format)
                == "about your usual Tuesday")
        #expect(ActivityComparison.phrase(value: 3600, history: usual, weekday: "Tuesday", format: format)
                == "about your usual Tuesday")
    }

    @Test func aboutIsTenMinutesOrTenPercentWhicheverIsWider() {
        // Median 10 h: 10% is an hour, wider than ten minutes.
        let long: [TimeInterval] = [36_000, 36_000, 36_000]
        #expect(ActivityComparison.verdict(value: 36_000 + 3000, history: long) == .about)
        #expect(ActivityComparison.verdict(value: 36_000 + 4000, history: long) == .more(4000))
        // Median 30 min: ten minutes is wider than 10%.
        let short: [TimeInterval] = [1800, 1800, 1800]
        #expect(ActivityComparison.verdict(value: 2400, history: short) == .about)
        #expect(ActivityComparison.verdict(value: 2500, history: short) == .more(700))
    }

    @Test func historyIsTheSameWeekdayBeforeTheDay() {
        let values: [Date: TimeInterval] = [
            tuesday: 9999,                                   // the day itself
            days(back: 1): 100, days(back: 2): 200,
            days(back: 1, extra: 1): 5555,                  // a Wednesday
            days(back: 3, extra: -1): 6666,                 // a Monday
            calendar.date(byAdding: .day, value: 7, to: tuesday)!: 7777,  // next Tuesday
            days(back: 3): 0,                               // nothing counted
            days(back: 4): 400,
        ]
        let history = ActivityComparison.history(of: tuesday, in: values, calendar: calendar)
        #expect(history == [100, 200, 400])
    }

    @Test func historyReachesBackOnlyTheLookback() {
        let values: [Date: TimeInterval] = [days(back: ActivityComparison.lookbackWeeks): 50,
                                            days(back: ActivityComparison.lookbackWeeks + 1): 60]
        #expect(ActivityComparison.history(of: tuesday, in: values, calendar: calendar) == [50])
    }

    @Test func weekdayNameFollowsTheCalendar() {
        #expect(ActivityComparison.weekdayName(of: tuesday, calendar: calendar) == "Tuesday")
    }
}

@Suite struct ActivityDailyBarsGridTests {
    @Test func gridlinesAreTwoRoundTimesUnderTheCeiling() {
        #expect(ActivityDailyBars.gridlines(ceiling: 5 * 3600) == [7200, 14_400])
        #expect(ActivityDailyBars.gridlines(ceiling: 3 * 3600) == [3600, 7200])
        #expect(ActivityDailyBars.gridlines(ceiling: 40 * 60) == [900, 1800])
        #expect(ActivityDailyBars.gridlines(ceiling: 60).isEmpty)
    }
}

@Suite struct ActivitySectionBarTests {
    @Test func activeSectionIsTheLastOnePastTheThreshold() {
        let order: [ActivitySection] = [.overview, .bars, .week, .hours]
        let tops: [ActivitySection: CGFloat] = [.overview: -400, .bars: -20, .week: 300, .hours: 700]
        #expect(ActivitySection.active(tops: tops, order: order, threshold: 80) == .bars)
        #expect(ActivitySection.active(tops: [.overview: 200, .bars: 500], order: order, threshold: 80) == .overview)
        #expect(ActivitySection.active(tops: [:], order: order, threshold: 80) == .overview)
        #expect(ActivitySection.active(tops: tops, order: [], threshold: 80) == nil)
    }

    @Test func aPeriodShowsTheDayOrTheBarsNotBoth() {
        #expect(ActivitySection.shown(for: .today).contains(.day))
        #expect(!ActivitySection.shown(for: .today).contains(.bars))
        #expect(ActivitySection.shown(for: .week).contains(.bars))
        #expect(!ActivitySection.shown(for: .month).contains(.day))
    }
}
