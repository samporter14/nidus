import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct TodayOverviewTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(_ hour: Double, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4 + dayOffset))!.addingTimeInterval(hour * 3600)
    }
    private func stretch(_ from: Double, _ to: Double, app: String = "Word", site: String? = nil, title: String? = nil) -> FocusActivitySegment {
        FocusActivitySegment(start: at(from), end: at(to), appID: "id." + app, appName: app, site: site, title: title)
    }
    private func log(_ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: "2026-11-04")
        for stretch in stretches { log.add(stretch) }
        return log
    }
    private func session(_ from: Double, _ to: Double, dayOffset: Int = 0) -> SessionEntry {
        var entry = SessionEntry(start: at(from, dayOffset: dayOffset), end: at(to, dayOffset: dayOffset), focused: (to - from) * 3600,
                                 planned: nil, outcome: .completed, goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = [FocusActivity(appID: "id.Word", appName: "Word", seconds: (to - from) * 3600)]
        return entry
    }
    private func overview(_ log: ActivityDayLog = ActivityDayLog(day: "2026-11-04"), sessions: [SessionEntry] = [],
                          live: ActivityRibbon.Focus? = nil, liveFocused: TimeInterval = 0, tracking: Bool = true,
                          now: Double = 15, categorizer: ActivityCategorizer = ActivityCategorizer(categories: [], work: FocusCategory.workSeed)) -> TodayOverview {
        TodayOverview(log: log, sessions: sessions, live: live, liveFocused: liveFocused, tracking: tracking,
                      now: at(now), categorizer: categorizer, calendar: calendar)
    }

    /// Work holds Word; AI, Messaging and Video hold a site or an app each.
    private func sorted(_ more: [FocusCategory] = []) -> ActivityCategorizer {
        func category(_ id: String, _ name: String, apps: [String] = [], sites: [String] = []) -> FocusCategory {
            FocusCategory(id: id, name: name, symbol: "circle", apps: apps.map { BlockedApp(bundleID: $0, name: $0) }, websites: sites)
        }
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "id.Word", name: "Word")]
        return ActivityCategorizer(categories: [category("ai", "AI", sites: ["claude.ai"]),
                                                category("msg", "Messaging", apps: ["id.Slack"]),
                                                category("video", "Video", sites: ["youtube.com"])] + more, work: work)
    }

    @Test func totalsCountTimeAtTheMacAndFocus() {
        let today = overview(log([stretch(9, 10), stretch(10, 11.5, app: "Safari", site: "nature.com")]), sessions: [session(9, 10)])
        #expect(today.state == .data)
        #expect(today.atMac == 2.5 * 3600)
        #expect(today.focused == 3600)
    }

    @Test func theTotalsLineNamesBothTimesAndDropsAZeroOne() {
        let both = overview(log([stretch(9, 10)]), sessions: [session(9, 9.5)])
        #expect(TodayPopoverPiece.totals(both) == "\(ActivityDuration.string(3600)) \u{00B7} \(ActivityDuration.string(1800)) in focus")
        let none = overview(log([stretch(9, 10)]))
        #expect(TodayPopoverPiece.totals(none) == ActivityDuration.string(3600))
    }

    @Test func listsKeepThreeRowsLargestFirst() {
        let stretches = [stretch(8, 8.1, app: "A"), stretch(8.1, 8.5, app: "B"), stretch(8.5, 9.5, app: "C"),
                         stretch(9.5, 11.5, app: "D"), stretch(11.5, 12, app: "E")]
        let today = overview(log(stretches))
        #expect(today.apps.map(\.name) == ["D", "C", "E"])
        #expect(today.rows(.apps).map(\.name) == ["D", "C", "E"])
        #expect(today.maximum(for: .apps) == 2 * 3600)

        let sites = [stretch(8, 8.2, app: "Safari", site: "a.com"), stretch(9, 9.4, app: "Safari", site: "b.com"),
                     stretch(10, 11, app: "Safari", site: "c.com"), stretch(12, 12.6, app: "Safari", site: "d.com")]
        let browsing = overview(log(sites))
        #expect(browsing.rows(.websites).map(\.name) == ["c.com", "d.com", "b.com"])
        #expect(browsing.maximum(for: .websites) == 3600)

        let docs = [stretch(8, 8.2, title: "One"), stretch(9, 9.4, title: "Two"), stretch(10, 11, title: "Three"),
                    stretch(12, 12.6, title: "Four")]
        let writing = overview(log(docs))
        #expect(writing.rows(.documents).map(\.name) == ["Three", "Four", "Two"])
        #expect(writing.maximum(for: .documents) == 3600)
    }

    @Test func anEmptyDayWithTrackingOnIsEmpty() {
        let today = overview()
        #expect(today.state == .empty)
        #expect(today.atMac == 0 && today.focused == 0)
        #expect(today.rows(.apps).isEmpty)
        #expect(today.maximum(for: .documents) == 0)
    }

    @Test func anEmptyDayWithTrackingOffIsOff() {
        #expect(overview(tracking: false).state == .off)
    }

    @Test func sessionsTodayShowEvenWhenTrackingIsOff() {
        let today = overview(sessions: [session(9, 10)], tracking: false)
        #expect(today.state == .data)
        #expect(today.focused == 3600)
    }

    @Test func theRunningSessionIsABarAndAddsToFocus() {
        let live = ActivityRibbon.Focus(id: "live", sessionID: nil, start: at(14), end: at(15), name: "Draft")
        let today = overview(sessions: [session(9, 10)], live: live, liveFocused: 1200)
        #expect(today.ribbon.focus.contains { $0.id == "live" })
        #expect(today.ribbon.focus.count == 2)
        #expect(today.focused == 3600 + 1200)
    }

    @Test func aRunningSessionAloneIsData() {
        let live = ActivityRibbon.Focus(id: "live", sessionID: nil, start: at(14), end: at(15), name: "Draft")
        let today = overview(live: live, liveFocused: 600, tracking: false)
        #expect(today.state == .data)
        #expect(today.focused == 600)
    }

    @Test func sessionsFromYesterdayDoNotCount() {
        let today = overview(sessions: [session(9, 10, dayOffset: -1)])
        #expect(today.state == .empty)
        #expect(today.focused == 0)
        #expect(today.ribbon.focus.isEmpty)
    }

    @Test func theSpanRunsFromTheFirstHourToNow() {
        let today = overview(log([stretch(10.25, 11)]), now: 13.5)
        #expect(today.ribbon.span.start == at(10))
        #expect(today.ribbon.span.end == at(13.5))
    }

    @Test func theSpanIsNotPulledBackToTheMorning() {
        let today = overview(log([stretch(13.1, 13.4)]), now: 14)
        #expect(today.ribbon.span.start == at(13))
    }

    @Test func theSpanKeepsAnHourWhenNowIsClose() {
        let today = overview(log([stretch(10.25, 10.5)]), now: 10.5)
        #expect(today.ribbon.span.start == at(10))
        #expect(today.ribbon.span.end == at(11))
    }

    @Test func anEmptyDayIsAnHourEndingNow() {
        let today = overview(now: 15.5)
        #expect(today.ribbon.span == DateInterval(start: at(14.5), end: at(15.5)))
    }

    // MARK: Category line

    @Test func theCategoryLineKeepsTheThreeLongestAndFoldsTheRestIntoOther() {
        let day = log([stretch(8, 11, app: "Word"), stretch(11, 12, app: "Safari", site: "claude.ai"),
                       stretch(12, 12.5, app: "Slack"), stretch(12.5, 12.7, app: "Safari", site: "youtube.com"),
                       stretch(13, 13.2, app: "Notes")])
        let split = overview(day, categorizer: sorted()).categorySplit
        #expect(split?.parts.map(\.name) == ["Work", "AI", "Messaging", "Other"])
        // Other is Video and Uncategorized, which were not in the top three.
        #expect(split?.parts.last?.seconds == 0.2 * 3600 + 0.2 * 3600)
        #expect(split?.text(first: 2) == "Work \(ActivityDuration.string(3 * 3600)) \u{00B7} AI \(ActivityDuration.string(3600))")
    }

    @Test func uncategorizedIsNamedWhenItIsAmongTheThreeLongest() {
        let day = log([stretch(8, 9, app: "Word"), stretch(9, 12, app: "Notes"), stretch(12, 12.5, app: "Slack")])
        let split = overview(day, categorizer: sorted()).categorySplit
        #expect(split?.parts.map(\.name) == ["Uncategorized", "Work", "Messaging"])
    }

    @Test func fewGroupsMakeNoOther() {
        let split = overview(log([stretch(8, 9, app: "Word"), stretch(9, 10, app: "Slack")]), categorizer: sorted()).categorySplit
        #expect(split?.parts.map(\.name) == ["Messaging", "Work"])
    }

    @Test func theLineIsHiddenWhenNothingIsCategorized() {
        #expect(overview(log([stretch(8, 9, app: "Notes")]), categorizer: sorted()).categorySplit == nil)
        #expect(overview(log([stretch(8, 9, app: "Word")])).categorySplit == nil)
        #expect(overview().categorySplit == nil)
    }

    @Test func categoriesAreNotAPopoverList() {
        #expect(!ActivityListKind.popoverKinds.contains(.categories))
        #expect(overview(log([stretch(8, 9, app: "Word")]), categorizer: sorted()).rows(.categories).isEmpty)
    }
}
