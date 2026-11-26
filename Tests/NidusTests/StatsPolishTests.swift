import SwiftUI
import Testing
@testable import Nidus

@MainActor @Suite("Stats polish")
struct StatsPolishTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }
    private let locale = Locale(identifier: "en_GB")

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Sundays, a week apart, from `start`.
    private func sundays(from start: Date, count: Int) -> [Date] {
        (0..<count).map { calendar.date(byAdding: .day, value: 7 * $0, to: start)! }
    }

    @Test func firstColumnGetsItsMonthWhenTheNextIsFarOff() {
        // 2 Mar 2025 is a Sunday; April first appears at 6 Apr (index 5).
        let columns = ContributionGraph.monthLabelColumns(firstDays: sundays(from: date(2025, 3, 2), count: 8), calendar: calendar)
        #expect(columns == [0, 5])
    }

    @Test func firstColumnYieldsToASecondLabelWithinTwoColumns() {
        // 23 Feb, 2 Mar: March starts at index 1.
        let columns = ContributionGraph.monthLabelColumns(firstDays: sundays(from: date(2025, 2, 23), count: 6), calendar: calendar)
        #expect(!columns.contains(0))
        #expect(columns.contains(1))
    }

    @Test func noColumnsNoLabels() {
        #expect(ContributionGraph.monthLabelColumns(firstDays: [], calendar: calendar) == [])
    }

    private func week(_ minutes: [Int], future: Int = 0) -> [FocusStats.Day] {
        let start = date(2025, 3, 2)
        return minutes.enumerated().map { i, m in
            FocusStats.Day(date: calendar.date(byAdding: .day, value: i, to: start)!, focused: TimeInterval(m * 60),
                           isFuture: i >= minutes.count - future)
        }
    }

    @Test func weekSummaryNamesTotalDaysAndBestDay() {
        let text = ContributionGraph.weekSummary(week([0, 30, 80, 0, 60, 0, 60]), calendar: calendar, locale: locale)
        #expect(text == "Week of 2 March: 3 hr 50 min over 4 days, best Tuesday 1 hr 20 min")
    }

    @Test func weekSummaryOfAQuietWeek() {
        #expect(ContributionGraph.weekSummary(week([0, 0, 0, 0, 0, 0, 0]), calendar: calendar, locale: locale) == "Week of 2 March: no focus")
    }

    @Test func weekSummaryIgnoresDaysToCome() {
        let text = ContributionGraph.weekSummary(week([30, 0, 0, 0, 0, 0, 90], future: 1), calendar: calendar, locale: locale)
        #expect(text == "Week of 2 March: 30 min over 1 day, best Sunday 30 min")
    }

    @Test func graphShadesRiseAndFillOutUnderIncreasedContrast() {
        let normal = (1...4).map { FocusPalette.graphOpacity(level: $0) }
        let increased = (1...4).map { FocusPalette.graphOpacity(level: $0, contrast: .increased) }
        #expect(normal == normal.sorted())
        #expect(normal.last == 1)
        #expect(increased.last == 1)
        for (n, i) in zip(normal, increased) { #expect(i >= n) }
    }

    @Test func colourSwatchLabelsFollowTheSeriesNames() {
        #expect(CategoryColourPicker.label(forSlot: 1) == "Colour, Teal")
        #expect(CategoryColourPicker.label(forSlot: 8) == "Colour, Blue")
        #expect(Solanum.seriesNames.count == Solanum.seriesCount)
    }
}
