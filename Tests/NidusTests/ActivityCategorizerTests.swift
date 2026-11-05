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

struct ActivityOverrideTests {
    let google = category("search", sites: ["google.com"])
    let social = category("social", sites: ["x.com", "reddit.com"])
    let messaging = category("messaging", apps: [slack])
    let browsers = category("browsers", apps: [safari])

    func categorizer(_ overrides: ActivityOverrides, work: FocusCategory = FocusCategory.workSeed,
                     _ categories: [FocusCategory]? = nil) -> ActivityCategorizer {
        ActivityCategorizer(categories: categories ?? [google, social, messaging, browsers], work: work, overrides: overrides)
    }

    func overrides(_ group: ActivityGroup, appID: String? = nil, site: String? = nil, url: String? = nil) -> ActivityOverrides {
        var overrides = ActivityOverrides()
        overrides.set(group, appID: appID, appName: appID, site: site, url: url)
        return overrides
    }

    // Order: 1 site override, 2 site rule, 3 app override, 4 app list, 5 none.

    @Test func step1ASiteOverrideBeatsTheSitesOwnRule() {
        let c = categorizer(overrides(.category("messaging"), site: "x.com"))
        #expect(c.category(appID: safari, site: "x.com") == "messaging")
        #expect(c.category(appID: safari, site: "reddit.com") == "social")
    }

    @Test func step1ASiteOverrideBeatsAnAppOverrideOnTheBrowser() {
        var o = overrides(.work, appID: safari)
        o.set(.category("messaging"), appID: nil, site: "x.com")
        #expect(categorizer(o).category(appID: safari, site: "x.com") == "messaging")
    }

    @Test func step2ASiteRuleBeatsAnAppOverrideOnTheBrowser() {
        let c = categorizer(overrides(.work, appID: safari))
        #expect(c.category(appID: safari, site: "x.com") == "social")
    }

    @Test func step3AnAppOverrideCoversTheBrowserWhenNoSiteRuleMatches() {
        let c = categorizer(overrides(.work, appID: safari))
        #expect(c.category(appID: safari, site: "example.org") == "work")
        #expect(c.category(appID: safari, site: nil) == "work")
    }

    @Test func step3AnAppOverrideBeatsTheAppsInheritedGroup() {
        let c = categorizer(overrides(.category("social"), appID: slack))
        #expect(c.category(appID: slack, site: nil) == "social")
        #expect(categorizer(ActivityOverrides()).category(appID: slack, site: nil) == "messaging")
    }

    @Test func step4TheInheritedAppGroupAppliesWithoutOverrides() {
        let c = categorizer(overrides(.work, appID: notes))
        #expect(c.category(appID: slack, site: nil) == "messaging")
        #expect(c.category(appID: safari, site: "example.org") == "browsers")
    }

    @Test func step5NothingMatchingIsUncategorized() {
        let c = categorizer(overrides(.work, appID: notes))
        #expect(c.category(appID: "com.example.other", site: "example.org") == nil)
    }

    @Test func explicitUncategorizedBeatsInheritedMembership() {
        let o = overrides(.uncategorized, appID: slack)
        #expect(categorizer(o).category(appID: slack, site: nil) == nil)
        #expect(categorizer(o).group(appID: slack, site: nil) == .uncategorized)
        let site = overrides(.uncategorized, site: "x.com")
        #expect(categorizer(site).category(appID: safari, site: "x.com") == nil)
        // An explicit Uncategorized site does not fall through to the browser's list.
        #expect(categorizer(site).category(appID: safari, site: "x.com", url: "https://x.com/home") == nil)
    }

    @Test func aSiteOverrideCoversThatHostOnly() {
        let c = categorizer(overrides(.work, site: "reddit.com"))
        #expect(c.category(appID: safari, site: "reddit.com") == "work")
        #expect(c.category(appID: safari, site: nil, url: "https://www.reddit.com/r/swift") == "work")
        #expect(c.category(appID: safari, site: "old.reddit.com") == "social", "a subdomain keeps its own group")
    }

    @Test func aServiceLabelAndItsAddressShareOneOverride() {
        var o = ActivityOverrides()
        o.set(.work, appID: safari, site: "Google Docs")
        #expect(o.sites.keys.sorted() == ["docs.google.com"])
        let c = categorizer(o)
        #expect(c.category(appID: safari, site: "Google Docs") == "work")
        #expect(c.category(appID: safari, site: "docs.google.com", url: "https://docs.google.com/d/1") == "work")
        #expect(c.category(appID: safari, site: "mail.google.com") == "search")
    }

    @Test func anOverrideToADeletedCategoryIsIgnored() {
        let c = categorizer(overrides(.category("gone"), appID: slack))
        #expect(c.category(appID: slack, site: nil) == "messaging")
        let site = categorizer(overrides(.category("gone"), site: "x.com"))
        #expect(site.category(appID: safari, site: "x.com") == "social")
    }

    @Test func workStaysAValidTargetEvenWhenEmpty() {
        let c = categorizer(overrides(.category(ActivityCategorizer.workID), appID: notes))
        #expect(c.category(appID: notes, site: nil) == "work")
    }

    @Test func itemsWithNothingToNameAreNotStored() {
        var o = ActivityOverrides()
        let bare = o.set(.work, appID: nil, site: nil)
        let label = o.set(.work, appID: nil, site: "Capsid")
        #expect(!bare && !label)
        #expect(o.isEmpty)
    }

    @Test func aWebsiteIsKeyedByItsBareHostAndAnAppByItsBundleID() {
        var o = ActivityOverrides()
        o.set(.work, appID: safari, appName: "Safari", site: nil, url: "https://www.Example.com/a?b=1")
        o.set(.work, appID: slack, appName: "Slack", site: nil)
        #expect(o.sites["example.com"]?.name == "example.com")
        #expect(o.apps[slack]?.name == "Slack")
        o.remove(.site("example.com"))
        o.remove(.app(slack))
        #expect(o.isEmpty)
    }

    @Test func removingOrMovingACategoryTouchesOnlyItsOverrides() {
        var o = overrides(.category("social"), appID: slack)
        o.set(.category("messaging"), appID: nil, site: "x.com")
        o.set(.work, appID: nil, site: "reddit.com")
        var pruned = o
        pruned.removeCategory("social")
        #expect(pruned.apps.isEmpty && pruned.sites.keys.sorted() == ["reddit.com", "x.com"])
        var moved = o
        moved.moveCategory("social", to: "messaging")
        #expect(moved.apps[slack]?.group == .category("messaging"))
    }

    @Test func overridesRoundTripAndDropADamagedEntry() throws {
        var o = overrides(.category("social"), appID: slack)
        o.set(.uncategorized, appID: nil, site: "x.com")
        o.set(.work, appID: nil, site: "github.com")
        #expect(try JSONDecoder().decode(ActivityOverrides.self, from: JSONEncoder().encode(o)) == o)
        let damaged = Data("""
        {"apps":{"a":{"group":"work","name":"A"},"b":{"group":42}},"sites":{"x.com":{"group":"nonsense","name":"x"}}}
        """.utf8)
        let loaded = try JSONDecoder().decode(ActivityOverrides.self, from: damaged)
        #expect(loaded.apps.keys.sorted() == ["a"] && loaded.sites.isEmpty)
    }

    @Test func aDeletedCategoryDoesNotBreakTotals() {
        let c = categorizer(overrides(.category("gone"), appID: slack))
        #expect(c.totals(of: [stretch(slack, seconds: 60)]).map(\.id) == ["messaging"])
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
        let categories = [category("social", sites: ["x.com"])]
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: categories)
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
        let categories = [category("social", sites: ["x.com"])]
        let setup = FocusSetup(name: "Writing", minutes: 25, categoryIDs: ["work", "social"], mode: .block)
        #expect(setup.liveCategoryIDs(in: categories) == ["social"])
        let plan = SessionPlan(goal: "", duration: nil, mode: .block,
                               categories: categories.filter { setup.categoryIDs.contains($0.id) },
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

@MainActor
struct CountAsLeavesBlockingAloneTests {
    func model(_ name: String, categories: [FocusCategory], work: FocusCategory) -> NidusModel {
        let defaults = UserDefaults(suiteName: "local.sam.nidus.tests.\(name)")!
        defaults.removePersistentDomain(forName: "local.sam.nidus.tests.\(name)")
        let model = NidusModel()
        model.preferencesOverride = NidusHost.Preferences(defaults: defaults)
        model.categories = categories
        model.workGroup = work
        return model
    }

    /// What a session started now would block, from the model's own lists.
    func plan(_ model: NidusModel) throws -> SessionPlan {
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: model.categories.map(\.id), categories: model.categories)
        var request = SessionRequest()
        request.categoryIDs = model.categories.map(\.id)
        return try #require(request.resolved(with: defaults, length: { (25, false) })).plan
    }

    @Test func countingNeverChangesACategoryTheWorkListOrAPlan() throws {
        let excepted = category("social", apps: [slack], sites: ["x.com", "reddit.com"],
                                exceptions: [.init(kind: .subtree, address: "reddit.com/r/swift")])
        let model = model("blocking", categories: [excepted, category("search", sites: ["google.com"])],
                          work: work(apps: [notes], sites: ["github.com"]))
        let before = (model.categories, model.workGroup, try plan(model))
        let targets: [ActivityGroup] = [.work, .category("social"), .category("search"), .uncategorized]
        for target in targets {
            model.countActivity(appID: slack, appName: "Slack", site: nil, as: target)
            model.countActivity(appID: safari, site: "x.com", as: target)
            model.countActivity(appID: safari, site: "docs.google.com", as: target)
            model.countActivity(appID: safari, site: "Google Docs", url: "https://docs.google.com/d/1", as: target)
            model.countActivity(appID: notes, site: nil, as: target)
            model.countActivity(appID: safari, site: nil, url: "https://github.com/a/b", as: target)
            #expect(model.categories == before.0)
            #expect(model.workGroup == before.1)
            #expect(try plan(model) == before.2)
        }
        #expect(!model.activityOverrides.isEmpty)
    }

    @Test func countingChangesWhereTimeCountsAndRemovingRestoresIt() {
        let model = model("moves", categories: [category("social", sites: ["x.com"]), category("messaging", apps: [slack])],
                          work: work())
        #expect(model.activityAssignment(appID: safari, site: "x.com") == .category("social"))
        model.countActivity(appID: safari, site: "x.com", as: .work)
        model.countActivity(appID: slack, appName: "Slack", site: nil, as: .uncategorized)
        #expect(model.activityAssignment(appID: safari, site: "x.com") == .work)
        #expect(model.activityAssignment(appID: slack, site: nil) == .uncategorized)
        #expect(model.activityCategorizer.category(appID: safari, site: "x.com") == "work")
        model.removeActivityOverride(.site("x.com"))
        model.removeActivityOverride(.app(slack))
        #expect(model.activityAssignment(appID: safari, site: "x.com") == .category("social"))
        #expect(model.activityAssignment(appID: slack, site: nil) == .category("messaging"))
        #expect(model.activityOverrides.isEmpty)
    }

    @Test func aCategoryThatDoesNotExistStoresNothing() {
        let model = model("missing", categories: [category("social", sites: ["x.com"])], work: work())
        model.countActivity(appID: nil, site: "x.com", as: .category("missing"))
        model.countActivity(appID: nil, site: nil, as: .work)
        #expect(model.activityOverrides.isEmpty)
    }

    @Test func deletingACategoryTakesItsOverridesWithIt() {
        let model = model("deleted", categories: [category("social", sites: ["x.com"]), category("ai", sites: ["claude.ai"])],
                          work: work())
        model.countActivity(appID: nil, site: "example.org", as: .category("ai"))
        model.countActivity(appID: nil, site: "example.net", as: .category("social"))
        model.deleteCategory("ai")
        #expect(model.activityOverrides.sites.keys.sorted() == ["example.net"])
    }

    @Test func aFileWithoutOverridesLoadsEmpty() throws {
        let defaults = UserDefaults(suiteName: "local.sam.nidus.tests.oldoverrides")!
        defaults.removePersistentDomain(forName: "local.sam.nidus.tests.oldoverrides")
        defaults.set(try JSONEncoder().encode(FocusCategory.presets), forKey: NidusModel.Key.categories)
        let model = NidusModel()
        model.preferencesOverride = NidusHost.Preferences(defaults: defaults)
        #expect(model.activityOverrides.isEmpty)
        defaults.set(Data("not json".utf8), forKey: NidusModel.Key.activityOverrides)
        #expect(model.activityOverrides.isEmpty)
        model.countActivity(appID: nil, site: "x.com", as: .work)
        #expect(model.activityOverrides.sites.keys.sorted() == ["x.com"])
    }
}

struct ActivityOverridesRoutingTests {
    @Test func theEditorOpensInsideTheBlockingTab() {
        #expect(SettingsRoute.resolve(NidusModel.activityOverridesPageID) == SettingsRoute(tab: .blocking, pushes: true))
    }
}
