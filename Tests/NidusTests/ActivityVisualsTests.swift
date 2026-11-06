import Foundation
import Testing
@testable import Nidus

/// The arithmetic under the day ribbon, the hour grid and the open rows.
@MainActor
@Suite struct ActivityVisualsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func date(_ day: Int, month: Int = 11, _ hour: Double = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!.addingTimeInterval(hour * 3600)
    }
    private func at(_ hour: Double) -> Date { date(4, hour) }
    private func minutes(_ hour: Double, _ count: Double) -> (Date, Date) { (at(hour), at(hour).addingTimeInterval(count * 60)) }
    private func category(_ id: String, _ name: String, apps: [String] = [], sites: [String] = []) -> FocusCategory {
        FocusCategory(id: id, name: name, symbol: "circle", apps: apps.map { BlockedApp(bundleID: $0, name: $0) }, websites: sites)
    }
    private var work: FocusCategory {
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "id.Word", name: "Word")]
        return work
    }
    private var categorizer: ActivityCategorizer {
        ActivityCategorizer(categories: [category("social", "Social", apps: ["id.Feed"], sites: ["reddit.com"]),
                                         category("chat", "Messaging", apps: ["id.Slack"])], work: work)
    }
    private func stretch(_ start: Date, _ end: Date, _ app: String = "Word", site: String? = nil, title: String? = nil) -> FocusActivitySegment {
        FocusActivitySegment(start: start, end: end, appID: "id." + app, appName: app, site: site, title: title, url: nil)
    }
    private func block(_ id: String, _ range: (Date, Date), _ series: Int, _ name: String) -> ActivityRibbon.Block {
        ActivityRibbon.Block(id: id, start: range.0, end: range.1, series: series, name: name, detail: nil)
    }
    private func merged(_ blocks: [ActivityRibbon.Block]) -> [ActivityRibbon.Block] {
        ActivityRibbonBands.merged(blocks) { $0 == 0 ? "Work" : "Social" }
    }

    // MARK: Category blocks

    @Test func runsOfOneCategoryJoinAcrossASmallGap() {
        let bands = merged([block("a", minutes(9, 20), 0, "Word"), block("b", minutes(9.4, 20), 0, "Excel")])
        #expect(bands.count == 1)
        #expect(bands[0].name == "Work")
        #expect(bands[0].detail == "Excel, Word" || bands[0].detail == "Word, Excel")
        #expect(bands[0].seconds == 40 * 60)
    }

    @Test func aLongGapKeepsRunsApart() {
        let bands = merged([block("a", minutes(9, 20), 0, "Word"), block("b", minutes(11, 20), 0, "Word")])
        #expect(bands.count == 2)
    }

    @Test func aSliverGoesIntoWhatItInterrupted() {
        let bands = merged([block("a", minutes(9, 30), 0, "Word"), block("b", minutes(9.5, 0.5), 1, "Feed"),
                            block("c", (at(9.5).addingTimeInterval(30), at(10)), 0, "Word")])
        #expect(bands.count == 1)
        #expect(bands[0].series == 0)
        // The interruption stays in the detail and in the time.
        #expect(bands[0].detail?.contains("Feed") == true)
        #expect(bands[0].end == at(10))
    }

    @Test func aMergedBlockCountsOnlyTheTimeInsideIt() {
        let bands = merged([block("a", minutes(9, 20), 0, "Word"), block("b", minutes(9.4, 20), 0, "Word")])
        #expect(bands[0].end.timeIntervalSince(bands[0].start) == 44 * 60)
        #expect(bands[0].seconds == 40 * 60)
    }

    @Test func aLongRunIsNeverAbsorbed() {
        let bands = merged([block("a", minutes(9, 30), 0, "Word"), block("b", minutes(9.5, 30), 1, "Feed"),
                            block("c", minutes(10, 30), 0, "Word")])
        #expect(bands.map(\.series) == [0, 1, 0])
    }

    @Test func theNamesOverflowIntoACount() {
        let names = ["A", "B", "C", "D", "E"]
        let blocks = names.enumerated().map { index, name in
            block(name, minutes(9 + Double(index) / 4, 10 + Double(names.count - index)), 0, name)
        }
        #expect(merged(blocks).first?.detail == "A, B, C and 2 more")
    }

    @Test func aColorIsTheCategorysNotItsRank() {
        #expect(categorizer.order(of: ActivityCategorizer.workID) == 0)
        #expect(categorizer.order(of: "chat") == 2)
        #expect(categorizer.order(of: "gone") == nil)
    }

    // MARK: Hour grid

    private func index(_ date: Date) -> (Int, Int) {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        return (parts.weekday! - 1, parts.hour!)
    }

    @Test func workBlockableAndTheRestFallApart() {
        let map = ActivityHeatmap(stretches: [stretch(at(9), at(9.5)), stretch(at(9.5), at(9.75), "Feed"), stretch(at(9.75), at(10), "Finder")],
                                  categorizer: categorizer, calendar: calendar)
        let (weekday, hour) = index(at(9))
        let cell = map[weekday: weekday, hour: hour]
        #expect(cell.work == 1800)
        #expect(cell.distraction == 900)
        #expect(cell.other == 900)
        #expect(map.maximum == 3600)
    }

    @Test func anHourLeansToWhatFilledMostOfIt() {
        #expect(ActivityHeatmap.Cell(work: 600, distraction: 300, other: 100).leader == .work)
        #expect(ActivityHeatmap.Cell(work: 300, distraction: 600, other: 100).leader == .distraction)
        // Five minutes of messages don't turn an uncategorized hour red.
        #expect(ActivityHeatmap.Cell(distraction: 300, other: 3300).leader == .other)
        #expect(ActivityHeatmap.Cell(work: 300, distraction: 300).leader == .work)
    }

    @Test func aSiteCountsAsItsCategoryInsideABrowser() {
        let map = ActivityHeatmap(stretches: [stretch(at(9), at(10), "Safari", site: "reddit.com")], categorizer: categorizer, calendar: calendar)
        let (weekday, hour) = index(at(9))
        #expect(map[weekday: weekday, hour: hour].distraction == 3600)
    }

    @Test func aStretchIsCutAtEachHour() {
        let map = ActivityHeatmap(stretches: [stretch(at(9.5), at(11.25))], categorizer: categorizer, calendar: calendar)
        let weekday = index(at(9)).0
        #expect(map[weekday: weekday, hour: 9].work == 1800)
        #expect(map[weekday: weekday, hour: 10].work == 3600)
        #expect(map[weekday: weekday, hour: 11].work == 900)
    }

    @Test func aStretchOverMidnightCountsOnBothDays() {
        let map = ActivityHeatmap(stretches: [stretch(date(4, 23.5), date(5, 0.5))], categorizer: categorizer, calendar: calendar)
        let wednesday = index(date(4)).0, thursday = index(date(5)).0
        #expect(wednesday != thursday)
        #expect(map[weekday: wednesday, hour: 23].work == 1800)
        #expect(map[weekday: thursday, hour: 0].work == 1800)
    }

    @Test func theRepeatedHourSumsWhenClocksGoBack() {
        // November 1: 1 a.m. happens twice in Detroit, so midnight to 3 a.m. is four hours.
        let start = date(1), end = date(1).addingTimeInterval(4 * 3600)
        let map = ActivityHeatmap(stretches: [stretch(start, end)], categorizer: categorizer, calendar: calendar)
        let sunday = index(start).0
        #expect(map[weekday: sunday, hour: 0].work == 3600)
        #expect(map[weekday: sunday, hour: 1].work == 7200)
        #expect(map[weekday: sunday, hour: 2].work == 3600)
        #expect(map[weekday: sunday, hour: 3].work == 0)
    }

    @Test func theSkippedHourStaysEmptyWhenClocksGoForward() {
        // March 8: 2 a.m. doesn't happen in Detroit.
        let start = date(8, month: 3), end = date(8, month: 3).addingTimeInterval(3 * 3600)
        let map = ActivityHeatmap(stretches: [stretch(start, end)], categorizer: categorizer, calendar: calendar)
        let sunday = index(start).0
        #expect(map[weekday: sunday, hour: 0].work == 3600)
        #expect(map[weekday: sunday, hour: 1].work == 3600)
        #expect(map[weekday: sunday, hour: 2].work == 0)
        #expect(map[weekday: sunday, hour: 3].work == 3600)
    }

    @Test func everySecondOfADayLandsInTheGrid() {
        let start = date(1), end = date(2)
        let map = ActivityHeatmap(stretches: [stretch(start, end)], categorizer: categorizer, calendar: calendar)
        #expect(map.cells.map(\.total).reduce(0, +) == end.timeIntervalSince(start))
    }

    @Test func aQuietHourStillShowsBesideTheBusiestOne() {
        var quiet = ActivityHeatmap.Cell()
        quiet.work = 60
        #expect(ActivityHourHeatmap.strength(of: quiet, peak: 3600) > 0.25)
        #expect(ActivityHourHeatmap.strength(of: .init(work: 3600), peak: 3600) == 1)
        #expect(ActivityHourHeatmap.strength(of: quiet, peak: 0) == 0)
    }

    // MARK: Hour grid cache

    private func signature(_ version: Int = 0) -> ActivityHeatmapSignature {
        ActivityHeatmapSignature(version: version, excluded: [], work: work, categories: [], overrides: ActivityOverrides())
    }
    private func dayLog(_ key: String, _ day: Int) -> ActivityDayLog {
        var log = ActivityDayLog(day: key)
        log.add(stretch(date(day, 9), date(day, 10)))
        return log
    }
    private actor Loads {
        var asked: [[String]] = []
        func note(_ keys: [String]) { asked.append(keys) }
    }

    @Test func aFinishedDayIsReadOnce() async {
        let cache = ActivityHeatmapCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let logs = [dayLog("2026-11-03", 3)]
        let keys = ["2026-11-02", "2026-11-03"]
        let load: @Sendable ([String]) async -> [ActivityDayLog] = { missing in
            await loads.note(missing)
            return logs.filter { missing.contains($0.day) }
        }
        let first = await cache.heatmap(days: keys, today: "2026-11-09", live: nil, signature: signature(), categorizer: sorter, calendar: cal, load: load)
        let second = await cache.heatmap(days: keys, today: "2026-11-09", live: nil, signature: signature(), categorizer: sorter, calendar: cal, load: load)
        #expect(first == second)
        #expect(first.maximum == 3600)
        // Including the day with no file.
        #expect(await loads.asked == [keys])
    }

    @Test func todayIsAddedFreshAndNeverKept() async {
        let cache = ActivityHeatmapCache(), sorter = categorizer, cal = calendar
        var today = dayLog("2026-11-04", 4)
        let once = await cache.heatmap(days: ["2026-11-04"], today: "2026-11-04", live: today, signature: signature(), categorizer: sorter, calendar: cal) { _ in [] }
        #expect(once.maximum == 3600)
        #expect(await cache.cachedDays == 0)
        today.add(stretch(date(4, 9), date(4, 10).addingTimeInterval(-1800)))
        today.add(stretch(date(4, 11), date(4, 12)))
        let twice = await cache.heatmap(days: ["2026-11-04"], today: "2026-11-04", live: today, signature: signature(), categorizer: sorter, calendar: cal) { _ in [] }
        #expect(twice != once)
    }

    @Test func todayWithNothingWrittenYetIsNotRememberedAsEmpty() async {
        let cache = ActivityHeatmapCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let map = await cache.heatmap(days: ["2026-11-04"], today: "2026-11-04", live: nil, signature: signature(), categorizer: sorter,
                                      calendar: cal) { missing in
            await loads.note(missing)
            return []
        }
        #expect(map.isEmpty)
        #expect(await cache.cachedDays == 0)
        #expect(await loads.asked.isEmpty)
    }

    @Test func aChangedRuleStartsOver() async {
        let cache = ActivityHeatmapCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let logs = [dayLog("2026-11-03", 3)]
        let load: @Sendable ([String]) async -> [ActivityDayLog] = { missing in
            await loads.note(missing)
            return logs
        }
        _ = await cache.heatmap(days: ["2026-11-03"], today: "2026-11-09", live: nil, signature: signature(1), categorizer: sorter, calendar: cal, load: load)
        _ = await cache.heatmap(days: ["2026-11-03"], today: "2026-11-09", live: nil, signature: signature(2), categorizer: sorter, calendar: cal, load: load)
        #expect(await loads.asked.count == 2)
    }

    // MARK: What's inside an app

    private func row(_ app: String, site: String? = nil, title: String? = nil, _ seconds: TimeInterval) -> FocusActivity {
        FocusActivity(appID: "id." + app, appName: app, site: site, title: title, seconds: seconds)
    }

    @Test func aBrowserOpensToItsSitesThenPages() throws {
        let tree = ActivityDrill.tree([row("Safari", site: "nature.com", title: "One", 300), row("Safari", site: "nature.com", title: "Two", 100),
                                       row("Safari", site: "nature.com", title: "One", 50), row("Safari", site: "reddit.com", title: "Feed", 600)])
        let sites = try #require(tree["id.Safari"])
        #expect(sites.map(\.name) == ["reddit.com", "nature.com"])
        #expect(sites[1].seconds == 450)
        #expect(sites[1].children.map(\.name) == ["One", "Two"])
        #expect(sites[1].children[0].seconds == 350)
    }

    @Test func aDocumentAppOpensToItsFiles() throws {
        let tree = ActivityDrill.tree([row("Word", title: "Thesis.docx", 900), row("Word", title: "Notes.docx", 100)])
        let files = try #require(tree["id.Word"])
        #expect(files.map(\.name) == ["Thesis.docx", "Notes.docx"])
        #expect(files.allSatisfy { $0.children.isEmpty })
    }

    @Test func aDocumentServiceListsItsDocumentsNotTheAppSuffix() throws {
        let tree = ActivityDrill.tree([row("Safari", site: "Google Docs", title: "Plan - Google Docs", 120)])
        let site = try #require(tree["id.Safari"]?.first)
        #expect(site.children.map(\.name) == ["Plan"])
    }

    @Test func anAppWithNothingNamedInsideHasNoEntry() {
        #expect(ActivityDrill.tree([row("Finder", 900)]).isEmpty)
    }

    @Test func unnamedTimeStaysSoTheRowsAddUp() throws {
        let tree = ActivityDrill.tree([row("Safari", site: "nature.com", title: "One", 300), row("Safari", 120)])
        let rows = try #require(tree["id.Safari"])
        #expect(rows.last?.id == ActivityDrill.unnamedID)
        #expect(rows.map(\.seconds).reduce(0, +) == 420)
        let brief = ActivityDrill.tree([row("Safari", site: "nature.com", title: "One", 300), row("Safari", 30)])
        #expect(brief["id.Safari"]?.count == 1)
    }

    @Test func aSiteWithNoPageNamesHasNothingUnder() throws {
        let tree = ActivityDrill.tree([row("Safari", site: "nature.com", 300)])
        let site = try #require(tree["id.Safari"]?.first)
        #expect(site.seconds == 300)
        #expect(site.children.isEmpty)
    }

    @Test func appsDontMixAndEmptyRowsDontCount() {
        let tree = ActivityDrill.tree([row("Safari", site: "a.com", 60), row("Chrome", site: "b.com", 60), row("Chrome", site: "c.com", 0)])
        #expect(tree["id.Safari"]?.map(\.name) == ["a.com"])
        #expect(tree["id.Chrome"]?.map(\.name) == ["b.com"])
    }
}
