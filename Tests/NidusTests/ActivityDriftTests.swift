import Foundation
import Testing
@testable import Nidus

/// Drift chains, the hour detail, the absorbed strips and the day a click opens.
@MainActor
@Suite struct ActivityDriftTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func date(_ day: Int, _ hour: Double = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!.addingTimeInterval(hour * 3600)
    }
    /// Seconds after 9:00 on November 4.
    private func at(_ seconds: TimeInterval) -> Date { date(4, 9).addingTimeInterval(seconds) }
    private func category(_ id: String, _ name: String, apps: [String] = [], sites: [String] = []) -> FocusCategory {
        FocusCategory(id: id, name: name, symbol: "circle", apps: apps.map { BlockedApp(bundleID: $0, name: $0) }, websites: sites)
    }
    private var work: FocusCategory {
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "id.Word", name: "Word")]
        return work
    }
    private var categories: [FocusCategory] {
        [category("social", "Social", apps: ["id.Feed"], sites: ["reddit.com", "x.com"]), category("chat", "Messaging", apps: ["id.Slack"])]
    }
    private var categorizer: ActivityCategorizer { ActivityCategorizer(categories: categories, work: work) }
    private func stretch(_ start: TimeInterval, _ seconds: TimeInterval, _ app: String = "Word", site: String? = nil,
                         continuity: Int = 0) -> FocusActivitySegment {
        FocusActivitySegment(start: at(start), end: at(start + seconds), appID: "id." + app, appName: app, site: site, continuity: continuity)
    }
    private func chains(_ stretches: [FocusActivitySegment], sorter: ActivityCategorizer? = nil) -> [ActivityDriftChain] {
        ActivityDrift.chains(in: stretches, categorizer: sorter ?? categorizer)
    }
    /// Five minutes of Word from 0, then `run` seconds of Feed `gap` after it.
    private func plain(gap: TimeInterval = 0, run: TimeInterval = 300, origin: TimeInterval = 300) -> [ActivityDriftChain] {
        chains([stretch(0, origin), stretch(origin + gap, run, "Feed")])
    }

    // MARK: Edges

    @Test func aChainNamesBothSidesAndItsTime() {
        let found = plain()
        #expect(found.count == 1)
        #expect(found[0].origin == "Word")
        #expect(found[0].target == "Feed")
        #expect(found[0].category == "social")
        #expect(found[0].fromWork)
        #expect(found[0].count == 1)
        #expect(found[0].seconds == 300)
    }

    @Test func theGapBetweenTheSidesStopsAtTwoMinutes() {
        #expect(plain(gap: 119).count == 1)
        #expect(plain(gap: 120).count == 1)
        #expect(plain(gap: 121).isEmpty)
    }

    @Test func aDistractionNeedsThreeMinutes() {
        #expect(plain(run: 179).isEmpty)
        #expect(plain(run: 180).count == 1)
        #expect(plain(run: 181).count == 1)
    }

    @Test func aShortOriginIsRejected() {
        #expect(plain(origin: 179).isEmpty)
        #expect(plain(origin: 180).count == 1)
        #expect(chains([stretch(0, 1), stretch(1, 300, "Feed")]).isEmpty)
    }

    @Test func aContinuityBreakEndsThePossibility() {
        #expect(chains([stretch(0, 300), stretch(300, 300, "Feed", continuity: 1)]).isEmpty)
    }

    @Test func aContinuityBreakSplitsARun() {
        let split = [stretch(0, 300), stretch(300, 120, "Feed"), stretch(420, 120, "Feed", continuity: 1)]
        #expect(chains(split).isEmpty)
    }

    @Test func aRunJoinsAcrossAMinuteAndNoMore() {
        func run(gap: TimeInterval) -> [FocusActivitySegment] {
            [stretch(0, 300), stretch(300, 100, "Feed"), stretch(400 + gap, 100, "Feed")]
        }
        #expect(chains(run(gap: 60)).first?.seconds == 200)
        #expect(chains(run(gap: 61)).isEmpty)
    }

    @Test func anOriginJoinsAcrossAMinuteToo() {
        #expect(chains([stretch(0, 100), stretch(160, 100), stretch(260, 300, "Feed")]).count == 1)
        #expect(chains([stretch(0, 100), stretch(161, 100), stretch(261, 300, "Feed")]).isEmpty)
    }

    @Test func aShortInterruptionStaysInTheRunAndOutOfItsTime() {
        let found = chains([stretch(0, 300), stretch(300, 100, "Feed"), stretch(400, 29), stretch(429, 100, "Slack"), stretch(529, 10, "Feed")])
        #expect(found.count == 1)
        #expect(found[0].seconds == 210)
        #expect(found[0].target == "Feed")
        #expect(found[0].category == "social")
    }

    @Test func thirtySecondsIsNoLongerAnInterruption() {
        #expect(chains([stretch(0, 300), stretch(300, 100, "Feed"), stretch(400, 30), stretch(430, 100, "Feed")]).isEmpty)
    }

    @Test func anInterruptionNeedsDistractionOnBothSides() {
        // The trailing Word is short, and ends the run rather than joining it.
        let found = chains([stretch(0, 300), stretch(300, 200, "Feed"), stretch(500, 20), stretch(520, 300, "Finder")])
        #expect(found.count == 1)
        #expect(found[0].seconds == 200)
    }

    @Test func aDistractionAfterADistractionHasNoOrigin() {
        let found = chains([stretch(0, 300), stretch(300, 300, "Feed"), stretch(690, 300, "Slack")])
        #expect(found.count == 1)
        #expect(found[0].target == "Feed")
    }

    @Test func anUncategorizedOriginCounts() {
        let found = chains([stretch(0, 300, "Finder"), stretch(300, 300, "Feed")])
        #expect(found.count == 1)
        #expect(found[0].origin == "Finder")
        #expect(!found[0].fromWork)
    }

    @Test func anEmptyWorkGroupStillFindsChains() {
        let sorter = ActivityCategorizer(categories: categories, work: FocusCategory.workSeed)
        #expect(chains([stretch(0, 300), stretch(300, 300, "Feed")], sorter: sorter).count == 1)
    }

    @Test func aSiteNamesABrowserSide() {
        let found = chains([stretch(0, 200), stretch(200, 100, "Finder"), stretch(300, 200, "Chrome", site: "x.com"), stretch(500, 100, "Feed")])
        #expect(found.first?.origin == "Word")
        #expect(found.first?.target == "x.com")
    }

    @Test func aCategoryOverrideChangesWhatCounts() {
        var overrides = ActivityOverrides()
        overrides.apps["id.Feed"] = ActivityOverrides.Entry(group: .work, name: "Feed")
        let sorter = ActivityCategorizer(categories: categories, work: work, overrides: overrides)
        #expect(chains([stretch(0, 300), stretch(300, 300, "Feed")], sorter: sorter).isEmpty)

        var moved = ActivityOverrides()
        moved.apps["id.Finder"] = ActivityOverrides.Entry(group: .category("chat"), name: "Finder")
        let other = ActivityCategorizer(categories: categories, work: work, overrides: moved)
        #expect(chains([stretch(0, 300), stretch(300, 300, "Finder")], sorter: other).first?.category == "chat")
    }

    @Test func anExcludedAppLeavesAGap() {
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(stretch(0, 300))
        log.add(stretch(300, 1, "Hidden"))
        log.add(stretch(301, 300, "Feed"))
        #expect(chains(log.hiding(["id.Hidden"]).stretches).isEmpty)
    }

    // MARK: Order

    private func chain(_ origin: String, _ target: String, work: Bool = false, count: Int = 1, seconds: TimeInterval = 300) -> ActivityDriftChain {
        ActivityDriftChain(origin: origin, target: target, category: "social", fromWork: work, count: count, seconds: seconds)
    }

    @Test func workComesFirstThenCountThenTime() {
        let top = ActivityDrift.top([chain("A", "x", count: 9), chain("B", "x", work: true), chain("C", "x", count: 2, seconds: 200), chain("D", "x", count: 2, seconds: 400)])
        #expect(top.map(\.origin) == ["B", "A", "D", "C"])
    }

    @Test func onlyTheTopFiveShow() {
        let top = ActivityDrift.top((0..<8).map { chain("App\($0)", "x", count: $0 + 1) })
        #expect(top.count == 5)
        #expect(top.first?.count == 8)
    }

    @Test func aChainReadsPlainly() {
        #expect(chain("Chrome", "x.com", count: 3, seconds: 1500).sentence == "Chrome \u{2192} x.com, 3 times, 25 min")
        #expect(chain("Chrome", "x.com").times == "once")
    }

    // MARK: Days

    private func signature(_ version: Int = 0) -> ActivityDigestSignature {
        ActivityDigestSignature(version: version, excluded: [], work: work, categories: categories, overrides: ActivityOverrides())
    }
    private func dayLog(_ day: Int, truncated: Bool = false) -> ActivityDayLog {
        let key = String(format: "2026-11-%02d", day)
        var log = ActivityDayLog(day: key)
        log.add(FocusActivitySegment(start: date(day, 9), end: date(day, 9.5), appID: "id.Word", appName: "Word"))
        log.add(FocusActivitySegment(start: date(day, 9.5), end: date(day, 10), appID: "id.Feed", appName: "Feed"))
        log.truncated = truncated
        return log
    }
    private func digest(_ logs: [ActivityDayLog], grid: [String] = [], chains: [String], today: String = "2026-11-20",
                        live: ActivityDayLog? = nil) async -> ActivityDayDigest {
        let cache = ActivityDigestCache(), sorter = categorizer, cal = calendar
        return await cache.digest(grid: grid, week: [], chains: chains, today: today, live: live, signature: signature(),
                                  categorizer: sorter, calendar: cal) { missing in logs.filter { missing.contains($0.day) } }
    }

    @Test func aRangeAddsItsDaysUp() async {
        let found = await digest([dayLog(2), dayLog(3)], chains: ["2026-11-02", "2026-11-03"])
        #expect(found.chains.count == 1)
        #expect(found.chains.values.first?.count == 2)
        #expect(found.chains.values.first?.seconds == 3600)
    }

    @Test func chainsCoverTheirOwnDaysNotTheGrids() async {
        // The grid looks back further than the day shown, as it does from Today.
        let found = await digest([dayLog(2), dayLog(3), dayLog(4)], grid: ["2026-11-02", "2026-11-03", "2026-11-04"], chains: ["2026-11-04"])
        #expect(found.chains.values.first?.count == 1)
        #expect(found.heatmap.maximum == 3600)
    }

    @Test func noChainDaysMeansNoChains() async {
        #expect(await digest([dayLog(2)], grid: ["2026-11-02"], chains: []).chains.isEmpty)
    }

    @Test func todayCountsAsItIs() async {
        let found = await digest([dayLog(3)], chains: ["2026-11-03", "2026-11-04"], today: "2026-11-04", live: dayLog(4))
        #expect(found.chains.values.first?.count == 2)
    }

    @Test func aTruncatedDayHasNoChains() async {
        #expect(await digest([dayLog(3, truncated: true)], chains: ["2026-11-03"]).chains.isEmpty)
        #expect(await digest([], chains: ["2026-11-04"], today: "2026-11-04", live: dayLog(4, truncated: true)).chains.isEmpty)
        // The rest of the day still counts.
        #expect(await digest([dayLog(3, truncated: true)], grid: ["2026-11-03"], chains: []).heatmap.maximum == 3600)
    }

    @Test func aChainNeverJoinsTwoLogs() async {
        var evening = ActivityDayLog(day: "2026-11-03")
        evening.add(FocusActivitySegment(start: date(3, 23.5), end: date(4), appID: "id.Word", appName: "Word"))
        var morning = ActivityDayLog(day: "2026-11-04")
        morning.add(FocusActivitySegment(start: date(4), end: date(4, 0.5), appID: "id.Feed", appName: "Feed"))
        let found = await digest([evening, morning], chains: ["2026-11-03", "2026-11-04"])
        #expect(found.chains.isEmpty)
    }

    @Test func theSameDaysAlwaysAddUpTheSame() async {
        let logs = (1...20).map { dayLog($0) }, keys = logs.map(\.day)
        let first = await digest(logs, grid: keys, chains: keys, today: "2026-11-25")
        let second = await digest(logs, grid: keys, chains: keys, today: "2026-11-25")
        #expect(first == second)
    }

    @Test func aMergeKeepsTheBiggerSidesCategoryAndAnyWork() {
        var first = ActivityDriftChain(origin: "A", target: "x", category: "social", fromWork: false, seconds: 200)
        first.add(ActivityDriftChain(origin: "A", target: "x", category: "chat", fromWork: true, seconds: 300))
        #expect(first.category == "chat")
        #expect(first.fromWork)
        #expect(first.count == 2)
        #expect(first.seconds == 500)
    }

    // MARK: Hour detail

    private var wednesdayAtNine: ActivityHourSlot {
        ActivityHourSlot(weekday: calendar.component(.weekday, from: date(4)) - 1, hour: 9)
    }

    @Test func theDetailAddsUpToTheSquare() {
        let stretches = [stretch(0, 1800), stretch(1800, 1200, "Chrome", site: "x.com"), stretch(3000, 1200, "Chrome", site: "nature.com"),
                         stretch(-600, 300, "Feed")]
        var detail = ActivityHourDetail(slot: wednesdayAtNine)
        detail.add(stretches, calendar: calendar)
        let cell = ActivityHeatmap(stretches: stretches, categorizer: categorizer, calendar: calendar)[weekday: wednesdayAtNine.weekday, hour: 9]
        #expect(detail.seconds == cell.total)
        #expect(detail.seconds == 3600)
        #expect(detail.apps.map(\.name) == ["Chrome", "Word"])
        #expect(detail.apps.map(\.seconds) == [1800, 1800])
        // Cut at ten, so the second page gives this hour ten of its twenty minutes.
        #expect(detail.sites.map(\.name) == ["x.com", "nature.com"])
        #expect(detail.sites.map(\.seconds) == [1200, 600])
    }

    @Test func theDetailAddsAcrossDaysAndCapsItsRows() {
        var detail = ActivityHourDetail(slot: wednesdayAtNine)
        for index in 0..<8 { detail.add([stretch(TimeInterval(index) * 60, 60, "App\(index)")], calendar: calendar) }
        let later = FocusActivitySegment(start: date(11, 9), end: date(11, 9.5), appID: "id.App3", appName: "App3")
        detail.add([later], calendar: calendar)
        #expect(detail.apps.count == ActivityHourDetail.rowLimit)
        #expect(detail.apps.first?.name == "App3")
        #expect(detail.apps.first?.seconds == 1860)
    }

    @Test func aDifferentWeekdayOrHourIsLeftOut() {
        var detail = ActivityHourDetail(slot: wednesdayAtNine)
        detail.add([FocusActivitySegment(start: date(5, 9), end: date(5, 9.5), appID: "id.Word", appName: "Word"),
                    FocusActivitySegment(start: date(4, 11), end: date(4, 11.5), appID: "id.Word", appName: "Word")], calendar: calendar)
        #expect(detail.seconds == 0)
        #expect(detail.apps.isEmpty)
    }

    @Test func onlyThatWeekdaysFilesAreRead() {
        // Four weeks to the end of November 4, the view from Today.
        let days = ActivityHourDetail.days(of: wednesdayAtNine, from: calendar.date(byAdding: .day, value: -27, to: date(4))!, to: date(5), calendar: calendar)
        #expect(days == ["2026-10-14", "2026-10-21", "2026-10-28", "2026-11-04"])
    }

    // MARK: Absorbed strips

    private func block(_ id: String, _ start: TimeInterval, _ seconds: TimeInterval, _ series: Int, _ name: String) -> ActivityRibbon.Block {
        ActivityRibbon.Block(id: id, start: at(start), end: at(start + seconds), series: series, name: name, detail: nil)
    }
    private func merged(_ blocks: [ActivityRibbon.Block]) -> [ActivityRibbon.Block] {
        ActivityRibbonBands.merged(blocks) { $0 == 0 ? "Work" : "Social" }
    }

    @Test func theLongerNeighborBeforeKeepsWhatItTakes() {
        let bands = merged([block("a", 0, 1800, 0, "Word"), block("b", 1800, 30, 1, "Feed"), block("c", 1830, 600, 0, "Word")])
        #expect(bands.count == 1)
        #expect(bands[0].absorbed == [ActivityRibbon.Absorbed(start: at(1800), end: at(1830), series: 1)])
    }

    @Test func theLongerNeighborAfterKeepsWhatItTakes() {
        let bands = merged([block("a", 0, 30, 1, "Feed"), block("b", 30, 1800, 0, "Word")])
        #expect(bands.count == 1)
        #expect(bands[0].series == 0)
        #expect(bands[0].start == at(0))
        #expect(bands[0].absorbed == [ActivityRibbon.Absorbed(start: at(0), end: at(30), series: 1)])
    }

    @Test func aJoinOfOneSeriesAbsorbsNothing() {
        let bands = merged([block("a", 0, 1200, 0, "Word"), block("b", 1500, 1200, 0, "Excel")])
        #expect(bands[0].absorbed.isEmpty)
        #expect(bands[0].absorbedNote == nil)
    }

    @Test func aBlockDrawsNothingOfItsOwnSeries() {
        // Feed takes the Word sliver, then Word takes Feed.
        let bands = merged([block("a", 0, 1800, 0, "Word"), block("b", 2100, 100, 1, "Feed"), block("c", 2200, 20, 0, "Word"),
                            block("d", 2220, 100, 1, "Feed"), block("e", 2400, 1800, 0, "Word")])
        #expect(bands.count == 1)
        #expect(bands[0].absorbed.allSatisfy { $0.series == 1 })
        #expect(bands[0].absorbed.count == 2)
    }

    @Test func touchingStripsOfOneCategoryJoin() {
        let bands = merged([block("a", 0, 1800, 0, "Word"), block("b", 1800, 20, 1, "Feed"), block("c", 1821, 20, 1, "Reddit"),
                            block("d", 1841, 1800, 0, "Word")])
        #expect(bands[0].absorbed == [ActivityRibbon.Absorbed(start: at(1800), end: at(1841), series: 1)])
    }

    @Test func touchingStripsOfTwoCategoriesStayApart() {
        let bands = merged([block("a", 0, 1800, 0, "Word"), block("b", 1800, 20, 1, "Feed"), block("c", 1820, 20, 2, "Slack"),
                            block("d", 1840, 1800, 0, "Word")])
        #expect(bands[0].absorbed.map(\.series) == [1, 2])
    }

    @Test func aBlockKeepsItsLongestStripsInOrder() {
        let limit = ActivityRibbonBands.stripLimit
        var blocks = [block("start", 0, 3600, 0, "Word")]
        var clock: TimeInterval = 3600
        for index in 0..<(limit + 6) {
            let length = TimeInterval(10 + index)
            blocks.append(block("s\(index)", clock, length, 1, "Feed"))
            blocks.append(block("w\(index)", clock + length, 200, 0, "Word"))
            clock += length + 200
        }
        let bands = merged(blocks)
        #expect(bands.count == 1)
        #expect(bands[0].absorbed.count == limit)
        #expect(bands[0].absorbed.map(\.start) == bands[0].absorbed.map(\.start).sorted())
        #expect(bands[0].absorbed.map(\.seconds).min() == TimeInterval(10 + 6))
        // Dropped from the strips, not from the words.
        let all = (0..<(limit + 6)).reduce(TimeInterval(0)) { $0 + TimeInterval(10 + $1) }
        #expect(bands[0].absorbedNote == "including Feed \(ActivityDuration.string(all))")
    }

    @Test func hoverNamesWhatWasAbsorbedWithItsTime() {
        let bands = merged([block("a", 0, 1800, 0, "Word"), block("b", 1800, 30, 1, "Feed"), block("c", 1830, 20, 1, "Slack"),
                            block("d", 1850, 1800, 0, "Word")])
        #expect(bands[0].absorbedNote == "including Feed 30 sec, Slack 20 sec")
        #expect(ActivityDayRibbon.description(of: bands[0]).hasSuffix("including Feed 30 sec, Slack 20 sec"))
    }

    @Test func aPlainBlockReadsAsItDid() {
        #expect(!ActivityDayRibbon.description(of: block("a", 0, 60, 0, "Word")).contains("including"))
    }

    @Test func coloringByAppAbsorbsNothing() {
        let ribbon = ActivityRibbon(stretches: [stretch(0, 1800), stretch(1800, 10, "Feed"), stretch(1810, 1800)], sessions: [],
                                    day: calendar.dateInterval(of: .day, for: date(4))!, now: date(4, 23), calendar: calendar)
        #expect(ribbon.blocks.count == 3)
        #expect(ribbon.blocks.allSatisfy { $0.absorbed.isEmpty })
    }

    // MARK: Opening a day

    @Test func aDayOpensAtItsOffset() {
        let now = date(5, 15)
        for back in [0, 1, 6] {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!
            let offset = ActivityPeriod.dayOffset(of: day, from: now, calendar: calendar)
            #expect(offset == -back)
            let interval = ActivityPeriod.today.interval(around: ActivityPeriod.today.anchor(offset: offset, from: now, calendar: calendar), calendar: calendar)
            #expect(interval.contains(day))
        }
    }

    @Test func aDayAcrossAClockChangeOpensAtItsOffset() {
        // November 1 runs 25 hours in Detroit.
        #expect(ActivityPeriod.dayOffset(of: date(1), from: date(2, 0.5), calendar: calendar) == -1)
        #expect(ActivityPeriod.dayOffset(of: date(1, 23), from: date(2, 0.5), calendar: calendar) == -1)
    }

    @Test func aDayNeverOpensAheadOfToday() {
        #expect(ActivityPeriod.dayOffset(of: date(6), from: date(5), calendar: calendar) == 0)
    }
}
