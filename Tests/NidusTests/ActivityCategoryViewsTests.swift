import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct ActivityCategoryViewsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(_ hour: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!.addingTimeInterval(hour * 3600)
    }
    private func stretch(_ from: Double, _ to: Double, app: String = "Safari", site: String? = nil, title: String? = nil,
                         url: String? = nil) -> FocusActivitySegment {
        FocusActivitySegment(start: at(from), end: at(to), appID: "id." + app, appName: app, site: site, title: title, url: url)
    }
    private func log(_ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: "2026-11-04")
        for stretch in stretches { log.add(stretch) }
        return log
    }
    private func day() -> DateInterval { calendar.dateInterval(of: .day, for: at(12))! }

    private func category(_ id: String, _ name: String, apps: [String] = [], sites: [String] = []) -> FocusCategory {
        FocusCategory(id: id, name: name, symbol: "circle", apps: apps.map { BlockedApp(bundleID: $0, name: $0) }, websites: sites)
    }
    /// Word is Work; claude.ai is AI; Slack is Messaging.
    private var categorizer: ActivityCategorizer {
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "id.Word", name: "Word")]
        return ActivityCategorizer(categories: [category("ai", "AI", sites: ["claude.ai"]),
                                                category("msg", "Messaging", apps: ["id.Slack"])], work: work)
    }
    private var morning: [FocusActivitySegment] {
        [stretch(8, 10, app: "Word", title: "Aims"), stretch(10, 11, site: "claude.ai", url: "https://claude.ai/chat/1"),
         stretch(11, 11.5, app: "Slack"), stretch(11.5, 12, site: "nature.com", url: "https://nature.com/a"),
         stretch(12, 12.5, app: "Safari", site: "claude.ai", title: "Notes")]
    }

    /// Work, AI, then Messaging and Uncategorized, in seconds.
    private let hours: [TimeInterval] = [7200, 5400, 1800, 1800]

    // MARK: Rows

    @Test func categoryRowsAreLongestFirstWithTheirShareOfAllCountedTime() {
        let scope = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar)
        let rows = scope.categoryTotals(using: categorizer)
        // Messaging and Uncategorized tie; the name breaks it.
        #expect(rows.map(\.id) == ["work", "ai", "msg", "uncategorized"])
        #expect(rows.map(\.seconds) == hours)
        #expect(rows.map(\.percentText) == ["44%", "33%", "11%", "11%"])
        #expect(abs(rows.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(abs(rows[0].share - 2 / 4.5) < 1e-9)
    }

    @Test func aSliverReadsLessThanOnePercentNotZero() {
        let total = ActivityCategoryTotal(id: "x", name: "X", symbol: "circle", seconds: 10, share: 0.002)
        #expect(total.percentText == "<1%")
        #expect(ActivityCategoryTotal(id: "x", name: "X", symbol: "circle", seconds: 10, share: 0.424).percentText == "42%")
    }

    @Test func timeFromASessionWithoutAStretchTimelineStillCounts() {
        var legacy = SessionEntry(start: at(14), end: at(15), focused: 3600, planned: nil, outcome: .completed,
                                  goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        legacy.activity = [FocusActivity(appID: "id.Slack", appName: "Slack", seconds: 1800)]
        let scope = ActivityScope(logs: [log(morning)], sessions: [legacy], calendar: calendar)
        let rows = scope.categoryTotals(using: categorizer)
        #expect(rows.first { $0.id == "msg" }?.seconds == 0.5 * 3600 + 1800)
    }

    @Test func aDayWhoseTimelineWasCutShortIsCountedFromItsTotals() {
        var cut = log(morning)
        cut.truncated = true
        cut.stretches = Array(cut.stretches.prefix(1))
        let scope = ActivityScope(logs: [cut], sessions: [], calendar: calendar)
        let rows = scope.categoryTotals(using: categorizer)
        let whole = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar).categoryTotals(using: categorizer)
        #expect(rows.map(\.id) == whole.map(\.id))
        #expect(rows.map(\.seconds) == whole.map(\.seconds))
    }

    // MARK: Filter

    @Test func aFilterRanksOnlyTheTimeInThatCategory() {
        let scope = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar)
        let ai = scope.totals(in: "ai", using: categorizer, calendar: calendar)
        #expect(ai.apps.map(\.name) == ["Safari"])
        #expect(ai.apps.first?.seconds == 1.5 * 3600)
        #expect(ai.sites.map(\.id) == ["claude.ai"])
        #expect(ai.documents.isEmpty)
        #expect(ai.sites.first?.url == "https://claude.ai/chat/1")
    }

    @Test func theUncategorizedFilterTakesWhatNoGroupClaims() {
        let scope = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar)
        let rest = scope.totals(in: ActivityCategorizer.uncategorizedID, using: categorizer, calendar: calendar)
        #expect(rest.sites.map(\.id) == ["nature.com"])
        #expect(rest.apps.map(\.name) == ["Safari"])
        #expect(rest.apps.first?.seconds == 0.5 * 3600)
    }

    @Test func aFilterKeepsTheFiguresWhole() {
        var entry = SessionEntry(start: at(9), end: at(10), focused: 3600, planned: nil, outcome: .completed,
                                 goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = [FocusActivity(appID: "id.Word", appName: "Word", seconds: 3600)]
        let scope = ActivityScope(logs: [log(morning)], sessions: [entry], calendar: calendar)
        let ai = scope.totals(in: "ai", using: categorizer, calendar: calendar)
        #expect(ai.focused == scope.totals.focused)
    }

    @Test func aFilterOnAnEmptyCategoryRanksNothing() {
        let scope = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar)
        #expect(scope.totals(in: "gone", using: categorizer, calendar: calendar).apps.isEmpty)
    }

    // MARK: Ribbon

    @Test func theRibbonCanBeColoredByCategory() {
        let ribbon = ActivityRibbon(stretches: morning, sessions: [], day: day(), now: at(23), colorBy: .category(categorizer),
                                    calendar: calendar)
        #expect(ribbon.series.map(\.name) == ["Work", "AI", "Messaging", "Uncategorized"])
        // Word, claude.ai, Slack, nature.com, then claude.ai again in Safari.
        #expect(ribbon.blocks.map(\.series) == [0, 1, 2, 3, 1])
        #expect(ribbon.series.map(\.seconds) == hours)
    }

    @Test func foldingToOtherStillHappensByCategory() {
        var groups = [category("a", "A", apps: ["id.A"]), category("b", "B", apps: ["id.B"]), category("c", "C", apps: ["id.C"]),
                      category("d", "D", apps: ["id.D"]), category("e", "E", apps: ["id.E"])]
        groups.append(category("f", "F", apps: ["id.F"]))
        let sorter = ActivityCategorizer(categories: groups, work: FocusCategory.workSeed)
        let stretches = zip(["A", "B", "C", "D", "E", "F"], [6.0, 5, 4, 3, 2, 1]).enumerated().map { index, pair in
            stretch(Double(index) * 7, Double(index) * 7 + pair.1, app: pair.0)
        }
        let ribbon = ActivityRibbon(stretches: stretches, sessions: [], day: day(), now: at(23), colorBy: .category(sorter), calendar: calendar)
        #expect(ribbon.series.map(\.name) == ["A", "B", "C", "D", "Other"])
        #expect(ribbon.blocks.last?.series == ActivityRibbon.namedSeries)
    }

    @Test func coloringByAppIsUnchanged() {
        let ribbon = ActivityRibbon(stretches: morning, sessions: [], day: day(), now: at(23), calendar: calendar)
        #expect(ribbon.series.map(\.name) == ["Safari", "Word", "Slack"])
    }

    // MARK: Count as

    @Test func aRowCountsAsWhatItIs() {
        let app = ActivityRank(id: "id.Safari", name: "Safari", seconds: 60)
        #expect(ActivityCountTarget(rank: app, kind: .apps)?.label == "Safari")
        #expect(ActivityCountTarget(rank: app, kind: .apps)?.site == nil)

        var site = ActivityRank(id: "nature.com", name: "nature.com", seconds: 60, url: "https://nature.com/a")
        site.sourceAppID = "id.Safari"
        site.sourceAppName = "Safari"
        let target = ActivityCountTarget(rank: site, kind: .websites)
        #expect(target?.site == "nature.com")
        #expect(target?.url == "https://nature.com/a")
        #expect(target?.label == "nature.com")

        #expect(ActivityCountTarget(rank: app, kind: .categories) == nil)
    }

    @Test func aDocumentCountsAsItsSiteElseItsApp() {
        let page = ActivityRank(id: "k", name: "Notes", seconds: 60, appID: "id.Safari", site: "claude.ai", appName: "Safari")
        #expect(ActivityCountTarget(rank: page, kind: .documents)?.label == "claude.ai")
        let file = ActivityRank(id: "k", name: "Aims", seconds: 60, appID: "id.Word", appName: "Word")
        let target = ActivityCountTarget(rank: file, kind: .documents)
        #expect(target?.label == "Word")
        #expect(target?.site == nil)
    }

    @Test func aSiteThatIsOnlyALabelIsNamedByItsApp() {
        var site = ActivityRank(id: "Capsid", name: "Capsid", seconds: 60)
        site.sourceAppID = "local.sam.bench"
        site.sourceAppName = "Capsid Bench"
        #expect(ActivityCountTarget(rank: site, kind: .websites)?.label == "Capsid Bench")
    }

    @Test func rowsCarryWhatCountAsNeeds() {
        let scope = ActivityScope(logs: [log(morning)], sessions: [], calendar: calendar)
        let site = scope.totals.sites.first { $0.id == "claude.ai" }
        #expect(site?.sourceAppID == "id.Safari")
        #expect(site?.url == "https://claude.ai/chat/1")
        let doc = ActivityScope(logs: [log([stretch(9, 10, app: "Safari", site: "Google Docs", title: "Notes - Google Docs")])],
                                sessions: [], calendar: calendar).totals.documents.first { $0.name == "Notes" }
        #expect(doc?.site == "Google Docs")
        #expect(doc?.appName == "Safari")
    }
}

@Suite("Web documents")
struct WebDocumentTests {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func stretch(site: String?, title: String?, url: String?, at offset: TimeInterval) -> FocusActivitySegment {
        FocusActivitySegment(start: day.addingTimeInterval(offset), end: day.addingTimeInterval(offset + 600),
                             appID: "com.apple.Safari", appName: "Safari", site: site, title: title, url: url)
    }

    private func totals(_ stretches: [FocusActivitySegment]) -> ActivityTotals {
        var log = ActivityDayLog(day: "2026-05-28")
        stretches.forEach { log.add($0) }
        return ActivityScope(logs: [log], sessions: []).totals
    }

    @Test("A Google doc is a document, not a website")
    func googleDocs() throws {
        let address = "https://docs.google.com/document/d/abc/edit"
        let totals = totals([stretch(site: "Google Docs", title: "Aims - Google Docs", url: address, at: 0),
                             stretch(site: "nature.com", title: nil, url: "https://nature.com/a", at: 600)])
        #expect(totals.sites.map(\.name) == ["nature.com"])
        let document = try #require(totals.documents.first)
        #expect(document.name == "Aims")
        #expect(document.subtitle == "Google Docs · Safari")
        #expect(document.url == address)
        #expect(document.reopenTarget == .page(URL(string: address)!))
    }

    @Test("Word on the web is a document too")
    func wordOnTheWeb() {
        let totals = totals([stretch(site: "Microsoft Word", title: "Chapter 3.docx - Word", url: "https://word.cloud.microsoft/x", at: 0)])
        #expect(totals.sites.isEmpty)
        #expect(totals.documents.map(\.name) == ["Chapter 3.docx"])
        #expect(totals.documents.first?.subtitle == "Microsoft Word · Safari")
    }

    @Test("Without a readable title it stays under the service's name")
    func untitled() {
        let totals = totals([stretch(site: "Google Docs", title: nil, url: "https://docs.google.com/document/d/abc", at: 0)])
        #expect(totals.sites.isEmpty)
        #expect(totals.documents.map(\.name) == ["Google Docs"])
    }

    @Test("A page goes under its site, however it was read")
    func pagesAreNotDocuments() {
        let safari = "com.apple.Safari"
        #expect(ActivityTimeline.documentName(appID: safari, title: "Cart : Target", site: "target.com") == nil)
        #expect(ActivityTimeline.documentName(appID: safari, title: "Home / X", site: "x.com") == nil)
        #expect(ActivityTimeline.documentName(appID: safari, title: "Chat", site: "Claude") == nil)
        #expect(ActivityTimeline.documentName(appID: safari, title: "Router", site: nil) == nil)
        #expect(ActivityTimeline.documentName(appID: "com.google.Chrome", title: "Router", site: "") == nil)
        #expect(ActivityTimeline.documentName(appID: "local.sam.bench", title: "Plate 3", site: "Capsid") == nil)

        let totals = totals([stretch(site: "target.com", title: "Cart : Target", url: "https://target.com/cart", at: 0),
                             stretch(site: "x.com", title: "Home / X", url: "https://x.com/home", at: 600),
                             stretch(site: "Google Docs", title: "Aims - Google Docs", url: nil, at: 1200)])
        #expect(totals.documents.map(\.name) == ["Aims"])
        #expect(Set(totals.sites.map(\.name)) == ["target.com", "x.com"])
    }

    @Test("A file in a document app stays a document")
    func filesAreDocuments() {
        #expect(ActivityTimeline.documentName(appID: "com.microsoft.Excel", title: "Plate.xlsx", site: nil) == "Plate.xlsx")
        #expect(ActivityTimeline.documentName(appID: "com.apple.TextEdit", title: "", site: nil) == nil)
        #expect(ActivityTimeline.documentName(appID: "com.apple.TextEdit", title: nil, site: nil) == nil)
    }

    @Test("Other sites keep their title out of it")
    func otherSites() {
        #expect(ActivityTimeline.documentName(title: "Aims - Google Docs", site: "Google Docs") == "Aims")
        #expect(!ActivityTimeline.isDocumentService("Claude"))
        #expect(!ActivityTimeline.isDocumentService(nil))
    }

    @Test("The ribbon names the document and colors it by its browser")
    func ribbon() throws {
        let doc = stretch(site: "Google Docs", title: "Aims - Google Docs", url: nil, at: 0)
        let ribbon = ActivityRibbon(stretches: [doc], sessions: [], day: DateInterval(start: day.addingTimeInterval(-3600), duration: 86_400),
                                    now: day.addingTimeInterval(700))
        let block = try #require(ribbon.blocks.first)
        #expect(block.name == "Aims")
        #expect(block.detail == "Google Docs · Safari")
        #expect(ribbon.series.map(\.name) == ["Safari"])
    }
}
