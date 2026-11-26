import Foundation
import SwiftUI
import Testing
@testable import Nidus

@MainActor
@Suite struct ActivityChartPolishTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(_ hour: Double, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4 + dayOffset))!.addingTimeInterval(hour * 3600)
    }
    private func stretch(_ from: Double, _ to: Double, app: String, dayOffset: Int = 0) -> FocusActivitySegment {
        FocusActivitySegment(start: at(from, dayOffset: dayOffset), end: at(to, dayOffset: dayOffset),
                             appID: "id." + app, appName: app, site: nil, title: nil)
    }
    private func ribbon(_ stretches: [FocusActivitySegment], dayOffset: Int = 0) -> ActivityRibbon {
        ActivityRibbon(stretches: stretches, sessions: [], day: calendar.dateInterval(of: .day, for: at(12, dayOffset: dayOffset))!,
                       now: at(23, dayOffset: dayOffset), calendar: calendar)
    }

    @Test func anAppKeepsItsTintWhateverItsRankThatDay() throws {
        let monday = ribbon([stretch(9, 11, app: "Xcode"), stretch(11, 12, app: "Mail")])
        let tuesday = ribbon([stretch(9, 11, app: "Mail", dayOffset: 1), stretch(11, 12, app: "Xcode", dayOffset: 1)], dayOffset: 1)
        let xcodeMonday = try #require(monday.series.firstIndex { $0.name == "Xcode" })
        let xcodeTuesday = try #require(tuesday.series.firstIndex { $0.name == "Xcode" })
        #expect(xcodeMonday != xcodeTuesday)
        #expect(monday.tint(ofSeries: xcodeMonday) == tuesday.tint(ofSeries: xcodeTuesday))
        #expect(monday.tint(ofSeries: xcodeMonday) == ActivityTint.app("id.Xcode"))
    }

    @Test func theFoldedOtherSeriesIsQuiet() {
        let apps = (0..<7).map { stretch(Double($0), Double($0) + 0.5, app: "App\($0)") }
        let day = ribbon(apps)
        let other = day.series.firstIndex { $0.id == ActivityRibbon.otherID }
        #expect(other != nil)
        #expect(day.tint(ofSeries: other ?? 0) == ActivityTint.quiet)
        #expect(day.tint(ofSeries: 99) == ActivityTint.quiet)
    }

    @Test func aCalloutKeepsFiveRowsAndCountsTheRest() {
        let items = (0..<8).map { (id: "\($0)", name: "Item \($0)", seconds: TimeInterval(($0 + 1) * 60), color: Optional<Color>.none) }
        let callout = ActivityCallout.ranked(title: "Mon", items: items)
        #expect(callout.rows.count == 5)
        #expect(callout.rows.first?.name == "Item 7")
        #expect(callout.footnote == "3 more")
    }

    @Test func anEmptyCalloutSaysNothingWasCounted() {
        let callout = ActivityCallout.ranked(title: "Tue 9\u{2013}10 AM", items: [("a", "A", 0, nil)])
        #expect(callout.rows.isEmpty)
        #expect(callout.footnote == "Nothing counted")
    }

    @Test func heatmapStrengthIsLinearFromAFloor() {
        let half = ActivityHeatmap.Cell(work: 1800)
        let full = ActivityHeatmap.Cell(work: 3600)
        #expect(ActivityHourHeatmap.strength(of: full, peak: 3600) == 1)
        #expect(abs(ActivityHourHeatmap.strength(of: half, peak: 3600) - 0.675) < 0.0001)
        #expect(ActivityHourHeatmap.strength(of: .init(work: 1), peak: 3600) > 0.34)
    }

    @Test func heatmapCalloutNamesOnlyWhatFilledTheHour() {
        let callout = ActivityHourHeatmap.callout(of: .init(work: 1800, distraction: 600), title: "Tue 9\u{2013}10 AM")
        #expect(callout.rows.map(\.name) == ["Work", "Distracting"])
    }
}
