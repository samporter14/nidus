import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct ActivityScopeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(_ hour: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!.addingTimeInterval(hour * 3600)
    }
    private func stretch(_ from: Double, _ to: Double, app: String = "Word", site: String? = nil, title: String? = nil) -> FocusActivitySegment {
        FocusActivitySegment(start: at(from), end: at(to), appID: "id." + app, appName: app, site: site, title: title)
    }
    private func log(_ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: "2026-11-04")
        for stretch in stretches { log.add(stretch) }
        return log
    }
    private func session(_ from: Double, _ to: Double) -> SessionEntry {
        var entry = SessionEntry(start: at(from), end: at(to), focused: (to - from) * 3600, planned: nil, outcome: .completed,
                                 goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = [FocusActivity(appID: "id.Word", appName: "Word", seconds: (to - from) * 3600)]
        return entry
    }
    private func day() -> DateInterval { calendar.dateInterval(of: .day, for: at(12))! }

    @Test func dailyRecordsCountOnceWhenASessionOverlapsThem() {
        let scope = ActivityScope(logs: [log([stretch(9, 12)])], sessions: [session(10, 11)], calendar: calendar)
        #expect(scope.hasDailyRecords)
        #expect(scope.totals.observed == 3 * 3600)
        #expect(scope.totals.focused == 3600)
    }

    @Test func narrowedToFocusCutsStretchesToSessions() {
        let scope = ActivityScope(logs: [log([stretch(9, 12)])], sessions: [session(10, 11)], narrowed: true, calendar: calendar)
        #expect(scope.totals.observed == 3600)
        #expect(scope.stretches.map(\.start) == [at(10)])
        #expect(scope.stretches.map(\.end) == [at(11)])
    }

    @Test func withoutDailyRecordsSessionsStillShow() {
        let scope = ActivityScope(logs: [], sessions: [session(10, 11)], calendar: calendar)
        #expect(!scope.hasDailyRecords)
        #expect(scope.totals.observed == 3600)
    }

    @Test func theRibbonIsColoredByAppSoABrowserKeepsItsPlace() {
        let stretches = [stretch(9, 10, app: "Safari", site: "nature.com"), stretch(10, 11, app: "Safari", site: "Claude"),
                         stretch(11, 11.5, app: "Word")]
        let ribbon = ActivityRibbon(stretches: stretches, sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(ribbon.series.map(\.name) == ["Safari", "Word"])
        #expect(ribbon.blocks.map(\.series) == [0, 0, 1])
    }

    @Test func hourLabelsLeaveEachOtherRoom() {
        let ribbon = ActivityRibbon(stretches: [stretch(9, 10)], sessions: [], day: day(), now: at(12), calendar: calendar)
        let hours = ribbon.ticks(calendar: calendar).map { calendar.component(.hour, from: $0) }
        #expect(hours == [9, 12, 15, 18])
    }

    @Test func aPageReopensAtItsLastAddressAndADocumentFallsBackToItsApp() {
        let first = FocusActivitySegment(start: at(9), end: at(10), appID: "id.S", appName: "Safari", site: "nature.com",
                                         title: "A", url: "https://nature.com/a")
        let second = FocusActivitySegment(start: at(11), end: at(12), appID: "id.S", appName: "Safari", site: "nature.com",
                                          title: "B", url: "https://nature.com/b")
        let word = stretch(12, 13, app: "Word", title: "Aims")
        let totals = ActivityScope(logs: [log([first, second, word])], sessions: [], calendar: calendar).totals
        #expect(totals.sites.first?.reopenTarget == .page(URL(string: "https://nature.com/b")!))
        #expect(totals.documents.first { $0.name == "A" }?.reopenTarget == .page(URL(string: "https://nature.com/a")!))
        #expect(totals.documents.first { $0.name == "Aims" }?.reopenTarget == .app("id.Word"))
        #expect(ActivityRank(id: "x", name: "x", seconds: 1).reopenTarget == nil)
    }

    @Test func seriesKeepAServiceAndFoldADomainIntoItsBrowser() {
        #expect(ActivityTotals.series(site: "Claude", appName: "Safari") == "Claude")
        #expect(ActivityTotals.series(site: "nature.com", appName: "Safari") == "Safari")
        #expect(ActivityTotals.series(site: nil, appName: "Word") == "Word")
    }

    @Test func theRibbonSpansTheWorkingDayAndGrowsToFitIt() {
        let plain = ActivityRibbon(stretches: [stretch(9, 10)], sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(plain.span.start <= at(8))
        #expect(plain.span.end >= at(18))
        let late = ActivityRibbon(stretches: [stretch(21, 22)], sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(late.span.end >= at(22))
    }

    @Test func theRibbonNamesTheLargestSeriesAndFoldsTheRest() {
        let apps = ["A", "B", "C", "D", "E", "F"]
        let stretches = apps.enumerated().map { index, app in stretch(Double(9 + index), Double(10 + index), app: app) }
        let ribbon = ActivityRibbon(stretches: stretches, sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(ribbon.series.count == ActivityRibbon.namedSeries + 1)
        #expect(ribbon.series.last?.id == ActivityRibbon.otherID)
        #expect(abs((ribbon.series.last?.seconds ?? 0) - 2 * 3600) < 1)
        #expect(ribbon.blocks.last?.series == ActivityRibbon.namedSeries)
    }

    @Test func aGapIsEmptyTrackAndATouchingStretchIsOneBlock() {
        let ribbon = ActivityRibbon(stretches: [stretch(9, 10), stretch(10, 11), stretch(12, 13)], sessions: [],
                                    day: day(), now: at(23), calendar: calendar)
        #expect(ribbon.blocks.count == 2)
        let gap = ribbon.position(of: at(11.5))
        #expect(ribbon.block(at: gap, reach: 0.001) == nil)
        #expect(ribbon.block(at: ribbon.position(of: at(9.5)), reach: 0)?.start == at(9))
        #expect(ribbon.block(at: gap, reach: 0.5) != nil, "A reach finds the nearest stretch")
    }

    @Test func aBlockNamesTheSiteOverTheApp() {
        let ribbon = ActivityRibbon(stretches: [stretch(9, 10, app: "Safari", site: "nature.com", title: "A paper")],
                                    sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(ribbon.blocks.first?.name == "nature.com")
        #expect(ribbon.blocks.first?.detail == "Safari · A paper")
    }

    @Test func aLiveSessionHasABarButNoRecap() {
        let live = ActivityRibbon.Focus(id: "live", sessionID: nil, start: at(14), end: at(15), name: "Focus")
        let ribbon = ActivityRibbon(stretches: [], sessions: [session(10, 11)], live: live, day: day(), now: at(15), calendar: calendar)
        #expect(ribbon.focus.count == 2)
        #expect(ribbon.focus.last?.sessionID == nil)
    }

    @Test func theSentenceNamesTheLead() {
        let lead = ActivityRank(id: "Word", name: "Word", seconds: 3600)
        #expect(ActivityOverviewLine.text(lead: lead, sessions: 0, withinFocus: false).hasPrefix("Most of it in Word"))
        #expect(ActivityOverviewLine.text(lead: lead, sessions: 1, withinFocus: true).hasSuffix("across 1 focus session."))
        #expect(ActivityOverviewLine.text(lead: lead, sessions: 2, withinFocus: false).hasSuffix("with 2 focus sessions."))
        #expect(ActivityOverviewLine.text(lead: nil, sessions: 0, withinFocus: false) == "Nothing was counted.")
    }
}
