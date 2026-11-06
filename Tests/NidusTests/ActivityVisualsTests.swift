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

    private func signature(_ version: Int = 0) -> ActivityDigestSignature {
        ActivityDigestSignature(version: version, excluded: [], work: work, categories: [], overrides: ActivityOverrides())
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
        let cache = ActivityDigestCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let logs = [dayLog("2026-11-03", 3)]
        let keys = ["2026-11-02", "2026-11-03"]
        let load: @Sendable ([String]) async -> [ActivityDayLog] = { missing in
            await loads.note(missing)
            return logs.filter { missing.contains($0.day) }
        }
        let first = await cache.digest(grid: keys, week: [], today: "2026-11-09", live: nil, signature: signature(), categorizer: sorter, calendar: cal, load: load)
        let second = await cache.digest(grid: keys, week: [], today: "2026-11-09", live: nil, signature: signature(), categorizer: sorter, calendar: cal, load: load)
        #expect(first == second)
        #expect(first.heatmap.maximum == 3600)
        // Including the day with no file.
        #expect(await loads.asked == [keys])
    }

    @Test func todayIsAddedFreshAndNeverKept() async {
        let cache = ActivityDigestCache(), sorter = categorizer, cal = calendar
        var today = dayLog("2026-11-04", 4)
        let once = await cache.digest(grid: ["2026-11-04"], week: [], today: "2026-11-04", live: today, signature: signature(), categorizer: sorter, calendar: cal) { _ in [] }
        #expect(once.heatmap.maximum == 3600)
        #expect(await cache.cachedDays == 0)
        today.add(stretch(date(4, 9), date(4, 10).addingTimeInterval(-1800)))
        today.add(stretch(date(4, 11), date(4, 12)))
        let twice = await cache.digest(grid: ["2026-11-04"], week: [], today: "2026-11-04", live: today, signature: signature(), categorizer: sorter, calendar: cal) { _ in [] }
        #expect(twice != once)
    }

    @Test func todayWithNothingWrittenYetIsNotRememberedAsEmpty() async {
        let cache = ActivityDigestCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let map = await cache.digest(grid: ["2026-11-04"], week: [], today: "2026-11-04", live: nil, signature: signature(), categorizer: sorter,
                                      calendar: cal) { missing in
            await loads.note(missing)
            return []
        }
        #expect(map.heatmap.isEmpty)
        #expect(await cache.cachedDays == 0)
        #expect(await loads.asked.isEmpty)
    }

    @Test func aDayStillToComeIsNotRememberedAsEmpty() async {
        let cache = ActivityDigestCache(), loads = Loads(), sorter = categorizer, cal = calendar
        _ = await cache.digest(grid: ["2026-11-20"], week: [], today: "2026-11-05", live: nil, signature: signature(), categorizer: sorter,
                               calendar: cal) { missing in
            await loads.note(missing)
            return []
        }
        #expect(await cache.cachedDays == 0)
        #expect(await loads.asked.isEmpty)
    }

    @Test func aSelectedHourReadsFinishedDaysOnce() async {
        let cache = ActivityDigestCache(), loads = Loads()
        let slot = ActivityHourSlot(weekday: 3, hour: 9), days = ["2026-10-28", "2026-11-04"]
        let build: @Sendable () async -> ActivityHourDetail = {
            await loads.note(days)
            return ActivityHourDetail(slot: slot)
        }
        _ = await cache.pastHour(slot, days: days, signature: signature(), build: build)
        _ = await cache.pastHour(slot, days: days, signature: signature(), build: build)
        #expect(await loads.asked.count == 1)
        _ = await cache.pastHour(ActivityHourSlot(weekday: 3, hour: 10), days: days, signature: signature(), build: build)
        #expect(await loads.asked.count == 2)
        _ = await cache.pastHour(ActivityHourSlot(weekday: 3, hour: 10), days: days, signature: signature(1), build: build)
        #expect(await loads.asked.count == 3)
    }

    @Test func aChangedRuleStartsOver() async {
        let cache = ActivityDigestCache(), loads = Loads(), sorter = categorizer, cal = calendar
        let logs = [dayLog("2026-11-03", 3)]
        let load: @Sendable ([String]) async -> [ActivityDayLog] = { missing in
            await loads.note(missing)
            return logs
        }
        _ = await cache.digest(grid: ["2026-11-03"], week: [], today: "2026-11-09", live: nil, signature: signature(1), categorizer: sorter, calendar: cal, load: load)
        _ = await cache.digest(grid: ["2026-11-03"], week: [], today: "2026-11-09", live: nil, signature: signature(2), categorizer: sorter, calendar: cal, load: load)
        #expect(await loads.asked.count == 2)
    }

    // MARK: Week at a glance

    private func week(ending day: Int, month: Int = 11, _ stretches: [FocusActivitySegment]) -> ActivityWeek {
        let digest = ActivityDayDigest(stretches: stretches, categorizer: categorizer, calendar: calendar)
        return ActivityWeek(ending: date(day, month: month), byDay: digest.byDay, categorizer: categorizer, calendar: calendar)
    }

    @Test func theWeekIsSevenDaysEndingOnTheLast() {
        let shown = week(ending: 5, [stretch(date(5, 9), date(5, 10))])
        #expect(shown.days.map(\.key) == ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"])
        #expect(shown.days.last?.seconds == 3600)
    }

    @Test func aMissingDayStaysAnEmptyBar() {
        let shown = week(ending: 5, [stretch(date(5, 9), date(5, 10))])
        #expect(shown.days.count == 7)
        #expect(shown.days[0].parts.isEmpty)
        #expect(shown.days[0].seconds == 0)
    }

    @Test func aDayStacksWorkFirstAndUncategorizedLast() {
        let shown = week(ending: 5, [stretch(date(5, 9), date(5, 10), "Finder"), stretch(date(5, 10), date(5, 11), "Slack"),
                                     stretch(date(5, 11), date(5, 12), "Feed"), stretch(date(5, 12), date(5, 13))])
        #expect(shown.days.last?.parts.map(\.name) == ["Work", "Social", "Messaging", "Uncategorized"])
        #expect(shown.days.last?.parts.last?.tint == ActivityInk.quietTint)
    }

    @Test func theSeventhDayBackIsLastWeek() {
        let shown = week(ending: 5, [stretch(date(4, 9), date(4, 10)), stretch(date(29, month: 10, 9), date(29, month: 10, 10.5)),
                                     stretch(date(30, month: 10, 9), date(30, month: 10, 9.5))])
        // Oct 30 is the first day of this week, Oct 29 the last of the one before.
        let work = shown.deltas.first { $0.id == ActivityCategorizer.workID }
        #expect(work?.thisWeek == 5400)
        #expect(work?.lastWeek == 5400)
        #expect(work?.change == 0)
    }

    @Test func timeBeforeLastWeekIsLeftOut() {
        let shown = week(ending: 5, [stretch(date(22, month: 10, 9), date(22, month: 10, 10)), stretch(date(5, 9), date(5, 10))])
        #expect(shown.deltas.first?.lastWeek == 0)
        #expect(!shown.hasLastWeek)
    }

    @Test func aCategoryGoneThisWeekStillShowsItsDrop() {
        let shown = week(ending: 5, [stretch(date(5, 9), date(5, 10)), stretch(date(28, month: 10, 9), date(28, month: 10, 10), "Feed")])
        let social = shown.deltas.first { $0.id == "social" }
        #expect(social?.thisWeek == 0)
        #expect(social?.change == -3600)
        #expect(shown.deltas.first?.id == ActivityCategorizer.workID)
    }

    @Test func noRecordLastWeekMeansNoComparison() {
        let shown = week(ending: 5, [stretch(date(5, 9), date(5, 10))])
        #expect(!shown.hasLastWeek)
    }

    @Test func aChangeReadsPlainly() {
        func delta(_ now: TimeInterval, _ then: TimeInterval) -> ActivityWeek.Delta {
            ActivityWeek.Delta(id: "x", name: "X", tint: 0, thisWeek: now, lastWeek: then)
        }
        #expect(delta(3600, 600).changeText == "+50 min")
        #expect(delta(600, 3600).changeText == "\u{2212}50 min")
        #expect(delta(600, 590).changeText == "Same")
    }

    @Test func midnightSplitsTheBars() {
        let shown = week(ending: 5, [stretch(date(4, 23.5), date(5, 0.5))])
        #expect(shown.days[5].seconds == 1800)
        #expect(shown.days[6].seconds == 1800)
    }

    @Test func aMidnightStretchInYesterdaysFileReachesTodayThroughTheCache() async {
        let cache = ActivityDigestCache(), sorter = categorizer, cal = calendar
        var yesterday = ActivityDayLog(day: "2026-11-04")
        yesterday.add(stretch(date(4, 23.5), date(5, 0.5)))
        var today = ActivityDayLog(day: "2026-11-05")
        today.add(stretch(date(5, 9), date(5, 10)))
        let logs = [yesterday]
        let digest = await cache.digest(grid: [], week: ["2026-11-04", "2026-11-05"], today: "2026-11-05", live: today,
                                        signature: signature(), categorizer: sorter, calendar: cal) { _ in logs }
        let work = ActivityCategorizer.workID
        #expect(digest.byDay["2026-11-04"]?[work] == 1800)
        #expect(digest.byDay["2026-11-05"]?[work] == 5400)
        // Asked for no grid days, so the grid stays empty.
        #expect(digest.heatmap.isEmpty)
    }

    @Test func aShortAndALongDayCountInFullAcrossClockChanges() {
        // November 1 runs 25 hours in Detroit, March 8 runs 23.
        let fall = week(ending: 2, [stretch(date(1), date(2))])
        #expect(fall.days[5].key == "2026-11-01")
        #expect(fall.days[5].seconds == 25 * 3600)
        let spring = week(ending: 9, month: 3, [stretch(date(8, month: 3), date(9, month: 3))])
        #expect(spring.days[5].key == "2026-03-08")
        #expect(spring.days[5].seconds == 23 * 3600)
    }

    @Test func theKeysStepByCalendarDayOverAClockChange() {
        let keys = ActivityWeek.keys(ending: date(2), calendar: calendar)
        #expect(keys.count == 14)
        #expect(Set(keys).count == 14)
        #expect(keys.contains("2026-11-01"))
        #expect(keys.contains("2026-10-20"))
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
