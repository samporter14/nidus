import Foundation
import Testing
@testable import Nidus

private let safari = "com.apple.Safari"
private let slack = "com.tinyspeck.slackmacgap"
private let notes = "com.apple.Notes"

private func category(_ id: String, apps: [String] = [], sites: [String] = [],
                      exceptions: [WebsiteException] = []) -> FocusCategory {
    FocusCategory(id: id, name: id.capitalized, symbol: "circle",
                  apps: apps.map { BlockedApp(bundleID: $0, name: $0) }, websites: sites,
                  websiteExceptions: exceptions)
}

private func work(apps: [String] = [], sites: [String] = [], exceptions: [WebsiteException] = []) -> FocusCategory {
    var group = FocusCategory.workSeed
    group.apps = apps.map { BlockedApp(bundleID: $0, name: $0) }
    group.websites = sites
    group.websiteExceptions = exceptions
    return group
}

private func stretch(_ app: String, site: String? = nil, url: String? = nil, seconds: TimeInterval = 60,
                     at offset: TimeInterval = 0) -> FocusActivitySegment {
    let start = Date(timeIntervalSince1970: 1_000_000 + offset)
    return FocusActivitySegment(start: start, end: start.addingTimeInterval(seconds), appID: app, appName: app,
                                site: site, url: url)
}

struct ActivityCategorizerTests {
    let social = category("social", sites: ["x.com", "reddit.com"])
    let messaging = category("messaging", apps: [slack], sites: ["discord.com"])
    let ai = category("ai", sites: ["claude.ai", "chatgpt.com"])

    func categorizer(work: FocusCategory = FocusCategory.workSeed, _ categories: [FocusCategory]? = nil) -> ActivityCategorizer {
        ActivityCategorizer(categories: categories ?? [social, messaging, ai], work: work)
    }

    @Test func anAppMatchesByBundleID() {
        #expect(categorizer().category(appID: slack, site: nil) == "messaging")
        #expect(categorizer().category(appID: notes, site: nil) == nil)
    }

    @Test func aSiteMatchesItsRuleAndSubdomains() {
        let c = categorizer()
        #expect(c.category(appID: safari, site: "x.com") == "social")
        #expect(c.category(appID: safari, site: "old.reddit.com") == "social")
        #expect(c.category(appID: safari, site: "notreddit.com") == nil)
    }

    @Test func anExceptionBeatsItsRule() {
        let excepted = category("social", sites: ["reddit.com"],
                                exceptions: [.init(kind: .subtree, address: "reddit.com/r/swift")])
        let c = categorizer([excepted])
        #expect(c.category(appID: safari, site: "reddit.com", url: "https://www.reddit.com/r/swift/top") == nil)
        #expect(c.category(appID: safari, site: "reddit.com", url: "https://www.reddit.com/r/funny") == "social")
    }

    @Test func anExceptedPageIsReadAgainstTheNextCategory() {
        let first = category("first", sites: ["example.com"], exceptions: [.init(kind: .subtree, address: "example.com/docs")])
        let second = category("second", sites: ["example.com/docs"])
        #expect(categorizer([first, second]).category(appID: safari, site: nil, url: "https://example.com/docs/a") == "second")
    }

    @Test func aBrowserWithAMatchingSiteCountsUnderTheSite() {
        let browserListed = category("browsers", apps: [safari])
        let c = categorizer([browserListed, social])
        #expect(c.category(appID: safari, site: "x.com") == "social")
    }

    @Test func aBrowserWithAnUnmatchedSiteFallsBackToTheBrowserOrNothing() {
        let browserListed = category("browsers", apps: [safari])
        #expect(categorizer([browserListed, social]).category(appID: safari, site: "example.org") == "browsers")
        #expect(categorizer([social]).category(appID: safari, site: "example.org") == nil)
        #expect(categorizer([social]).category(appID: safari, site: nil) == nil)
    }

    @Test func theFirstCategoryInTheUsersOrderWins() {
        let a = category("a", sites: ["example.com"])
        let b = category("b", sites: ["example.com"])
        #expect(categorizer([a, b]).category(appID: safari, site: "example.com") == "a")
        #expect(categorizer([b, a]).category(appID: safari, site: "example.com") == "b")
    }

    @Test func workIsCheckedFirst() {
        let c = categorizer(work: work(sites: ["claude.ai"], exceptions: []))
        #expect(c.category(appID: safari, site: "claude.ai") == ActivityCategorizer.workID)
        #expect(c.category(appID: safari, site: "chatgpt.com") == "ai")
    }

    @Test func workMatchesAppsAndSitesAndAnEmptyWorkMatchesNothing() {
        let c = categorizer(work: work(apps: [notes], sites: ["github.com"]))
        #expect(c.category(appID: notes, site: nil) == "work")
        #expect(c.category(appID: safari, site: "gist.github.com") == "work")
        #expect(categorizer().category(appID: notes, site: nil) == nil)
    }

    @Test func aSiteBeatsAWorkAppSoABrowserInWorkStillSendsSocialToSocial() {
        let c = categorizer(work: work(apps: [safari]))
        #expect(c.category(appID: safari, site: "x.com") == "social")
        #expect(c.category(appID: safari, site: "example.org") == "work")
    }

    @Test func aServiceLabelIsReadAsItsWebsite() {
        let docs = category("docs", sites: ["docs.google.com"])
        let c = categorizer([docs, ai])
        #expect(c.category(appID: safari, site: "Google Docs") == "docs")
        #expect(c.category(appID: safari, site: "Claude") == "ai")
        // The two local labels have no address; the app decides.
        #expect(c.category(appID: safari, site: "Claude Science") == nil)
        #expect(c.category(appID: "local.sam.bench", site: "Capsid") == nil)
    }

    @Test func theAddressIsPreferredToTheSite() {
        let c = categorizer([category("a", sites: ["example.com/private"]), category("b", sites: ["example.com"])])
        #expect(c.category(appID: safari, site: "example.com", url: "https://example.com/private/x") == "a")
        #expect(c.category(appID: safari, site: "example.com") == "b")
    }

    @Test func totalsGroupAndSortWithUncategorizedItsOwnEntry() {
        let c = categorizer(work: work(apps: [notes]))
        let totals = c.totals(of: [
            stretch(safari, site: "x.com", seconds: 120),
            stretch(slack, seconds: 300, at: 200),
            stretch(notes, seconds: 600, at: 600),
            stretch("com.example.other", seconds: 60, at: 1200),
            stretch(safari, site: "reddit.com", seconds: 80, at: 1300),
        ])
        #expect(totals.map(\.id) == ["work", "messaging", "social", "uncategorized"])
        #expect(totals.map(\.seconds) == [600, 300, 200, 60])
        #expect(abs(totals.map(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(totals.last?.name == "Uncategorized")
    }

    @Test func totalsFromRowsReadTheirSite() {
        let c = categorizer()
        let totals = c.totals(of: [
            FocusActivity(appID: safari, appName: "Safari", site: "x.com", seconds: 100),
            FocusActivity(appID: safari, appName: "Safari", site: "Claude", seconds: 50),
            FocusActivity(appID: safari, appName: "Safari", seconds: 25),
        ])
        #expect(totals.map(\.id) == ["social", "ai", "uncategorized"])
    }

    @Test func totalsIgnoreNonPositiveTimeAndEmptyInput() {
        #expect(categorizer().totals(of: [FocusActivitySegment]()).isEmpty)
        #expect(categorizer().totals(of: [FocusActivity(appID: slack, appName: "S", seconds: -5)]).isEmpty)
    }

    @Test func aDayOfStretchesIsFast() {
        let sites = (0..<150).map { "site\($0).example.com" } + ["x.com"]
        let c = categorizer([category("big", sites: (0..<80).map { "listed\($0).com" }), social, messaging, ai])
        let day = (0..<2048).map { i in
            stretch(safari, site: sites[i % sites.count], url: "https://\(sites[i % sites.count])/p\(i % 9)", seconds: 30,
                    at: Double(i) * 30)
        }
        let start = Date()
        let totals = c.totals(of: day)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(totals.map(\.seconds).reduce(0, +) == 2048 * 30)
    }
}

struct ActivityGroupEditingTests {
    func groups() -> ActivityGroups {
        ActivityGroups(
            work: FocusCategory.workSeed,
            categories: [category("social", sites: ["x.com", "reddit.com"]),
                         category("messaging", apps: [slack], sites: ["discord.com"]),
                         category("search", sites: ["google.com"])])
    }

    @Test func countingASiteMovesItOutOfTheOldGroup() {
        var g = groups()
        g.count(appID: nil, site: "x.com", as: .category("messaging"))
        #expect(g.assignment(appID: safari, site: "x.com") == .category("messaging"))
        #expect(g.categories[0].websites == ["reddit.com"])
        #expect(g.categories[1].websites == ["discord.com", "x.com"])
    }

    @Test func countingASiteAsWorkAddsItToWorkAndRemovesItElsewhere() {
        var g = groups()
        g.count(appID: nil, site: "reddit.com", as: .work)
        #expect(g.work.websites == ["reddit.com"])
        #expect(g.assignment(appID: safari, site: "reddit.com") == .work)
        #expect(g.categories[0].websites == ["x.com"])
    }

    @Test func uncategorizedTakesAnItemOutOfEveryGroup() {
        var g = groups()
        g.count(appID: nil, site: "reddit.com", as: .work)
        g.count(appID: nil, site: "reddit.com", as: .uncategorized)
        #expect(g.assignment(appID: safari, site: "reddit.com") == .uncategorized)
        #expect(g.work.websites.isEmpty && g.categories[0].websites == ["x.com"])
        g.count(appID: slack, site: nil, as: .uncategorized)
        #expect(g.assignment(appID: slack, site: nil) == .uncategorized)
        #expect(g.categories[1].apps.isEmpty)
    }

    @Test func countingAnAppMovesItAndNamesIt() {
        var g = groups()
        g.count(appID: slack, appName: "Slack", site: nil, as: .work)
        #expect(g.assignment(appID: slack, site: nil) == .work)
        #expect(g.work.apps == [BlockedApp(bundleID: slack, name: "Slack")])
        #expect(g.categories[1].apps.isEmpty)
        g.count(appID: slack, site: nil, as: .category("social"))
        #expect(g.work.apps.isEmpty && g.categories[0].apps.map(\.bundleID) == [slack])
    }

    @Test func aSiteWinsOverTheBrowserWhenBothAreGiven() {
        var g = groups()
        g.count(appID: safari, site: "x.com", as: .work)
        #expect(g.work.apps.isEmpty && g.work.websites == ["x.com"])
    }

    @Test func aBroaderRuleIsExceptedNotRewritten() {
        var g = groups()
        #expect(g.assignment(appID: safari, site: "docs.google.com") == .category("search"))
        g.count(appID: nil, site: "docs.google.com", as: .work)
        #expect(g.assignment(appID: safari, site: "docs.google.com") == .work)
        #expect(g.categories[2].websites == ["google.com"], "the broad rule stays")
        #expect(g.categories[2].websiteExceptions.count == 1)
        #expect(g.assignment(appID: safari, site: "mail.google.com") == .category("search"))
        // And back: the exception is taken back when the category is the target.
        g.count(appID: nil, site: "docs.google.com", as: .category("search"))
        #expect(g.assignment(appID: safari, site: "docs.google.com") == .category("search"))
        #expect(g.categories[2].websiteExceptions.isEmpty && g.work.websites.isEmpty)
    }

    @Test func aServiceLabelCountsByItsHost() {
        var g = groups()
        g.count(appID: safari, site: "Google Docs", as: .work)
        #expect(g.work.websites == ["docs.google.com"])
        #expect(g.assignment(appID: safari, site: "Google Docs") == .work)
    }

    @Test func aCategoryThatIsGoneChangesNothing() {
        var g = groups()
        let before = g
        g.count(appID: nil, site: "x.com", as: .category("missing"))
        #expect(g == before)
    }

    @Test func anItemWithNothingToNameChangesNothing() {
        var g = groups()
        let before = g
        g.count(appID: nil, site: nil, as: .work)
        #expect(g == before)
    }
}

@MainActor
struct WorkIsNeverBlockedTests {
    @Test func workIsNotAmongTheCategoriesAnySurfaceReads() {
        let model = NidusModel()
        #expect(!model.categories.contains { $0.id == ActivityCategorizer.workID })
        #expect(!FocusCategory.presets.contains { $0.id == ActivityCategorizer.workID })
        #expect(!FocusCategory.suggested(in: []).contains { $0.id == ActivityCategorizer.workID })
        #expect(!model.composerCategories.contains { $0.id == ActivityCategorizer.workID })
        #expect(!FocusCategory.defaultSelection.contains(ActivityCategorizer.workID))
    }

    @Test func aRequestNamingWorkBuildsAPlanWithoutIt() throws {
        let groups = ActivityGroups(work: work(apps: [notes], sites: ["github.com"],
                                               exceptions: [.init(kind: .subtree, address: "github.com/pulls")]),
                                    categories: [category("social", sites: ["x.com"])])
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: groups.categories)
        var request = SessionRequest()
        request.categoryIDs = ["work", "social"]
        let resolved = try #require(request.resolved(with: defaults, length: { (25, false) }))
        #expect(resolved.plan.websites == ["x.com"])
        #expect(resolved.plan.apps.isEmpty)
        #expect(resolved.plan.websiteExceptions.isEmpty)
        // A request for Work alone has nothing to block.
        request.categoryIDs = ["work"]
        #expect(request.resolved(with: defaults, length: { (25, false) }) == nil)
    }

    @Test func aSetupNamingWorkLeavesItOutOfItsCategories() {
        let groups = ActivityGroups(work: work(sites: ["github.com"]), categories: [category("social", sites: ["x.com"])])
        let setup = FocusSetup(name: "Writing", minutes: 25, categoryIDs: ["work", "social"], mode: .block)
        #expect(setup.liveCategoryIDs(in: groups.categories) == ["social"])
        let plan = SessionPlan(goal: "", duration: nil, mode: .block,
                               categories: groups.categories.filter { setup.categoryIDs.contains($0.id) },
                               reopensQuitApps: false)
        #expect(plan.websites == ["x.com"])
    }
}

@MainActor
struct WorkPreferencesTests {
    func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "local.sam.nidus.tests.\(name)")!
        defaults.removePersistentDomain(forName: "local.sam.nidus.tests.\(name)")
        return defaults
    }

    @Test func aPreferencesFileWithoutWorkLoadsAndGetsTheEmptyGroup() throws {
        let defaults = suite("oldfile")
        // What 0.6 saved: categories and a selection, no Work.
        defaults.set(try JSONEncoder().encode(FocusCategory.presets), forKey: NidusModel.Key.categories)
        defaults.set(try JSONEncoder().encode(["social"]), forKey: NidusModel.Key.selection)
        let preferences = NidusHost.Preferences(defaults: defaults)
        let loaded: FocusCategory = preferences.value(forKey: NidusModel.Key.workGroup, default: FocusCategory.workSeed)
        #expect(loaded == FocusCategory.workSeed && loaded.isEmpty)
        #expect(preferences.list(forKey: NidusModel.Key.categories, default: [FocusCategory]()).count == FocusCategory.presets.count)
    }

    @Test func workRoundTripsApartFromTheCategories() {
        let preferences = NidusHost.Preferences(defaults: suite("roundtrip"))
        let saved = work(apps: [notes], sites: ["github.com"])
        preferences.setValue(saved, forKey: NidusModel.Key.workGroup)
        let loaded: FocusCategory = preferences.value(forKey: NidusModel.Key.workGroup, default: FocusCategory.workSeed)
        #expect(loaded == saved)
        #expect(preferences.list(forKey: NidusModel.Key.categories, default: FocusCategory.presets) == FocusCategory.presets)
    }

    @Test func aDamagedWorkEntryFallsBackToTheEmptyGroup() {
        let defaults = suite("damaged")
        defaults.set(Data("{\"id\":\"work\"}".utf8), forKey: NidusModel.Key.workGroup)
        let preferences = NidusHost.Preferences(defaults: defaults)
        let loaded: FocusCategory = preferences.value(forKey: NidusModel.Key.workGroup, default: FocusCategory.workSeed)
        #expect(loaded == FocusCategory.workSeed)
    }
}
