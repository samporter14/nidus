import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct DriftBlockSuggestionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))! }
    private func key(back: Int) -> String {
        ActivityDayLog.key(for: calendar.date(byAdding: .day, value: -back, to: now)!, calendar: calendar)
    }
    private var categorizer: ActivityCategorizer {
        var mail = FocusCategory(id: "mail", name: "Mail", symbol: "e", apps: [], websites: ["mail.example.com"], role: .neutral)
        mail.role = .neutral
        let social = FocusCategory(id: "social", name: "Social", symbol: "s", apps: [BlockedApp(bundleID: "id.Feed", name: "Feed")],
                                   websites: ["reddit.com", "x.com"])
        return ActivityCategorizer(categories: [social, mail], work: FocusCategory.workSeed)
    }
    private func chain(_ target: String, appID: String? = nil, group: String = "social", count: Int = 1) -> ActivityDriftChain {
        var chain = ActivityDriftChain(origin: "Word", target: target, targetAppID: appID, groups: [group: 300], fromWork: true, seconds: 300)
        chain.count = count
        return chain
    }
    private func suggest(_ byDay: [String: [ActivityDriftChain]], dismissed: Set<String> = [], apps: Set<String> = [],
                         sites: [String] = []) -> DriftBlockSuggestion? {
        DriftBlockSuggester.suggestion(byDay: byDay, now: now, calendar: calendar, categorizer: categorizer,
                                       dismissed: dismissed, blockedApps: apps, blockedWebsites: sites)
    }

    @Test func thresholdIsFive() {
        #expect(suggest([key(back: 0): [chain("reddit.com", count: 4)]]) == nil)
        let found = suggest([key(back: 0): [chain("reddit.com", count: 5)]])
        #expect(found?.item == DriftItem(kind: .site, value: "reddit.com", name: "reddit.com"))
        #expect(found?.message == "You drifted to reddit.com 5 times this week. Add it to your block list?")
    }

    @Test func countsAcrossDaysInTheLastSevenOnly() {
        let spread = [key(back: 0): [chain("reddit.com", count: 2)], key(back: 6): [chain("reddit.com", count: 3)]]
        #expect(suggest(spread)?.count == 5)
        let old = [key(back: 0): [chain("reddit.com", count: 2)], key(back: 7): [chain("reddit.com", count: 3)]]
        #expect(suggest(old) == nil)
    }

    @Test func neutralTargetsAreNeverSuggested() {
        #expect(suggest([key(back: 0): [chain("mail.example.com", group: "mail", count: 9)]]) == nil)
        #expect(suggest([key(back: 0): [chain("Word", group: ActivityCategorizer.workID, count: 9)]]) == nil)
        #expect(suggest([key(back: 0): [chain("what", group: ActivityCategorizer.uncategorizedID, count: 9)]]) == nil)
    }

    @Test func dismissedItemsAreNotSuggestedAgain() {
        let days = [key(back: 0): [chain("reddit.com", count: 6)]]
        #expect(suggest(days, dismissed: ["site:reddit.com"]) == nil)
        #expect(suggest(days, dismissed: ["site:x.com"]) != nil)
    }

    @Test func blockedItemsAreSkipped() {
        let site = [key(back: 0): [chain("old.reddit.com", count: 6)]]
        #expect(suggest(site, sites: ["reddit.com"]) == nil)
        #expect(suggest(site, sites: ["notreddit.com"]) != nil)
        let app = [key(back: 0): [chain("Feed", appID: "id.Feed", count: 6)]]
        #expect(suggest(app, apps: ["id.Feed"]) == nil)
        #expect(suggest(app)?.item.kind == .app)
    }

    @Test func oneSuggestionHighestCountThenName() {
        let days = [key(back: 0): [chain("x.com", count: 6), chain("reddit.com", count: 7)]]
        #expect(suggest(days)?.item.value == "reddit.com")
        let tie = [key(back: 0): [chain("x.com", count: 6), chain("reddit.com", count: 6)]]
        #expect(suggest(tie)?.item.value == "reddit.com")
        // A blocked top item hands over to the next.
        #expect(suggest(days, sites: ["reddit.com"])?.item.value == "x.com")
    }

    @Test func addPutsTheItemInTheSelectionOnly() {
        let base = FocusCategory.presets
        let selection = ["social"]
        let site = DriftItem(kind: .site, value: "news.example.com", name: "news.example.com")
        var result = DriftBlockSuggester.adding(site, categories: base, selection: selection)
        #expect(result.selection == ["social", DriftBlockSuggester.categoryID])
        #expect(result.categories.dropLast() == base[...])
        #expect(result.categories.last?.websites == ["news.example.com"])
        let app = DriftItem(kind: .app, value: "id.Feed", name: "Feed")
        result = DriftBlockSuggester.adding(app, categories: result.categories, selection: result.selection)
        #expect(result.selection.filter { $0 == DriftBlockSuggester.categoryID }.count == 1)
        #expect(result.categories.last?.apps.map(\.bundleID) == ["id.Feed"])
        #expect(result.categories.last?.websites == ["news.example.com"])
    }

    @Test func aChainRemembersAnAppTarget() {
        let work = FocusCategory.workSeed
        var workWithWord = work
        workWithWord.apps = [BlockedApp(bundleID: "id.Word", name: "Word")]
        let sorter = ActivityCategorizer(categories: [FocusCategory(id: "social", name: "Social", symbol: "s",
                                                                    apps: [BlockedApp(bundleID: "id.Feed", name: "Feed")], websites: [])],
                                         work: workWithWord)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func seg(_ at: TimeInterval, _ app: String) -> FocusActivitySegment {
            FocusActivitySegment(start: start.addingTimeInterval(at), end: start.addingTimeInterval(at + 300), appID: "id." + app, appName: app)
        }
        let found = ActivityDrift.chains(in: [seg(0, "Word"), seg(300, "Feed")], categorizer: sorter)
        #expect(found.first?.targetAppID == "id.Feed")
    }
}
