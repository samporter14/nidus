import Foundation
import Testing
@testable import Nidus

private let safari = "com.apple.Safari"
private let chrome = "com.google.Chrome"
private let slack = "com.tinyspeck.slackmacgap"
private let claude = "com.anthropic.claudefordesktop"
private let prism = "com.GraphPad.Prism"

private func stretch(_ app: String, name: String? = nil, site: String? = nil, url: String? = nil,
                     seconds: TimeInterval = 60) -> FocusActivitySegment {
    let start = Date(timeIntervalSince1970: 1_000_000)
    return FocusActivitySegment(start: start, end: start.addingTimeInterval(seconds), appID: app,
                                appName: name ?? app, site: site, url: url)
}

struct ActivityUncategorizedTests {
    let messaging = FocusCategory(id: "messaging", name: "Messaging", symbol: "bubble",
                                  apps: [BlockedApp(bundleID: slack, name: "Slack")], websites: ["discord.com"])

    func items(_ stretches: [FocusActivitySegment], rows: [FocusActivity] = [],
               overrides: ActivityOverrides = ActivityOverrides()) -> [ActivityUncategorizedItem] {
        let categorizer = ActivityCategorizer(categories: [messaging], work: .workSeed, overrides: overrides)
        return ActivityUncategorized.items(stretches: stretches, rows: rows, using: categorizer, overrides: overrides)
    }

    @Test func onlyTimeNoGroupClaimsIsOfferedLongestFirst() {
        let found = items([
            stretch(slack, seconds: 500),
            stretch(claude, name: "Claude", seconds: 300),
            stretch(prism, name: "Prism", seconds: 100),
            stretch(claude, name: "Claude", seconds: 200),
            stretch(safari, site: "discord.com", url: "https://discord.com/channels/1", seconds: 900),
        ])
        #expect(found.map(\.name) == ["Claude", "Prism"])
        #expect(found.first?.seconds == 500)
        #expect(found.first?.subject == .app(claude))
    }

    @Test func websitesAreKeyedByHostAcrossBrowsersAndPages() {
        let found = items([
            stretch(chrome, site: "docs.google.com", url: "https://docs.google.com/spreadsheets/d/1", seconds: 120),
            stretch(safari, site: "docs.google.com", url: "https://docs.google.com/document/d/2", seconds: 60),
            stretch(safari, site: "Google Docs", seconds: 30),
        ])
        #expect(found.count == 1)
        #expect(found.first?.subject == .site("docs.google.com"))
        #expect(found.first?.isWebsite == true)
        #expect(found.first?.seconds == 210)
    }

    @Test func aBrowserWithNoPageIsOfferedAsLocalAndBrowserPagesNotAsTheBrowser() {
        let found = items([
            stretch(safari, seconds: 600),
            stretch(chrome, site: nil, url: "http://localhost:3000/app", seconds: 100),
            stretch(chrome, site: "intranet", seconds: 20),
        ])
        #expect(found.count == 1)
        #expect(found.first?.subject == .page(.local))
        #expect(found.first?.name == "Local and browser pages")
        #expect(found.first?.seconds == 720)
        #expect(found.contains { $0.subject == .app(safari) } == false)
    }

    @Test func claudeScienceTabsAreTheirOwnSubject() {
        let found = items([
            stretch(chrome, site: "Claude Science", seconds: 60),
            stretch(safari, site: "Claude Science", seconds: 40),
            stretch(safari, seconds: 10),
        ])
        #expect(found.map(\.subject) == [.page(.science), .page(.local)])
        #expect(found.first?.seconds == 100)
        #expect(found.first?.name == "Claude Science")
    }

    @Test func assigningTheLocalBucketCategorizesOnlyThatBucket() {
        var overrides = ActivityOverrides()
        overrides.set(.category("messaging"), subject: .page(.local), name: "Local and browser pages")
        let categorizer = ActivityCategorizer(categories: [messaging], work: .workSeed, overrides: overrides)
        #expect(categorizer.category(appID: safari, site: nil) == "messaging")
        #expect(categorizer.category(appID: chrome, site: nil, url: "http://localhost:8080/") == "messaging")
        #expect(categorizer.category(appID: safari, site: "Claude Science") == nil, "science is a separate bucket")
        #expect(categorizer.category(appID: safari, site: "neb.com", url: "https://neb.com/") == nil)
        #expect(categorizer.category(appID: prism, site: nil) == nil)
        // The bucket leaves the card once assigned, and the science tab stays.
        let found = items([stretch(safari, seconds: 30), stretch(safari, site: "Claude Science", seconds: 20)], overrides: overrides)
        #expect(found.map(\.subject) == [.page(.science)])
        var science = overrides
        science.set(.work, subject: .page(.science), name: "Claude Science")
        let both = ActivityCategorizer(categories: [messaging], work: .workSeed, overrides: science)
        #expect(both.category(appID: safari, site: "Claude Science") == ActivityCategorizer.workID)
    }

    @Test func aBrowserOverrideStillBeatsNothingAndPagesBeatTheApp() {
        var overrides = ActivityOverrides()
        overrides.set(.work, appID: safari, appName: "Safari", site: nil)
        let categorizer = ActivityCategorizer(categories: [messaging], work: .workSeed, overrides: overrides)
        #expect(categorizer.category(appID: safari, site: nil) == ActivityCategorizer.workID)
        #expect(items([stretch(safari, seconds: 30)], overrides: overrides).isEmpty)
    }

    @Test func subdomainsCarryTheirRegistrableDomain() {
        let found = items([
            stretch(chrome, site: "docs.google.com", url: "https://docs.google.com/x/1", seconds: 30),
            stretch(chrome, site: "neb.com", url: "https://neb.com/", seconds: 20),
            stretch(chrome, site: "news.bbc.co.uk", url: "https://news.bbc.co.uk/", seconds: 10),
        ])
        #expect(found.first { $0.name == "docs.google.com" }?.domain == "google.com")
        #expect(found.first { $0.name == "neb.com" }?.domain == nil)
        #expect(found.first { $0.name == "news.bbc.co.uk" }?.domain == "bbc.co.uk")
        let docs = found.first { $0.name == "docs.google.com" }!
        #expect(docs.subject(wholeDomain: true) == .domain("google.com"))
        #expect(docs.subject(wholeDomain: false) == .site("docs.google.com"))
    }

    @Test func aDomainOverrideTakesItsSubdomainsOffTheCard() {
        var overrides = ActivityOverrides()
        overrides.set(.uncategorized, subject: .domain("google.com"), name: "google.com and subdomains")
        let found = items([
            stretch(chrome, site: "docs.google.com", url: "https://docs.google.com/x/1", seconds: 30),
            stretch(chrome, site: "neb.com", url: "https://neb.com/", seconds: 20),
        ], overrides: overrides)
        #expect(found.map(\.name) == ["neb.com"])
    }

    @Test func itemsRunBiggestTrackedTimeFirstAcrossKinds() {
        let found = items(
            [
                stretch(prism, name: "Prism", seconds: 100),
                stretch(chrome, site: "neb.com", url: "https://neb.com/", seconds: 300),
                stretch(safari, seconds: 200),
                stretch(chrome, site: "Claude Science", seconds: 50),
                stretch(claude, name: "Claude", seconds: 50),
            ],
            rows: [FocusActivity(appID: prism, appName: "Prism", seconds: 250)])
        #expect(found.map(\.seconds) == [350, 300, 200, 50, 50])
        #expect(found.map(\.name) == ["Prism", "neb.com", "Local and browser pages", "Claude", "Claude Science"])
    }

    @Test func anOverrideTakesTheItemOffTheCardEvenLeave() {
        var overrides = ActivityOverrides()
        overrides.set(.uncategorized, appID: claude, appName: "Claude", site: nil)
        overrides.set(.work, appID: chrome, site: "benchling.com", url: "https://benchling.com/x")
        let found = items([
            stretch(claude, name: "Claude", seconds: 300),
            stretch(chrome, site: "benchling.com", url: "https://benchling.com/x", seconds: 300),
            stretch(prism, name: "Prism", seconds: 10),
        ], overrides: overrides)
        #expect(found.map(\.name) == ["Prism"])
    }

    @Test func choosingAnItemStoresTheSameOverrideCountAsWould() {
        let item = items([stretch(chrome, site: "neb.com", url: "https://www.neb.com/tools", seconds: 60)]).first!
        var overrides = ActivityOverrides()
        let stored = overrides.set(.work, appID: item.appID, appName: item.appName, site: item.site, url: item.url)
        #expect(stored)
        #expect(overrides.sites["neb.com"]?.group == .work)
        #expect(overrides.apps.isEmpty, "a website's choice never moves its browser")
    }

    @Test func rowsWithoutStretchesCountToo() {
        let found = items([stretch(prism, name: "Prism", seconds: 10)],
                          rows: [FocusActivity(appID: prism, appName: "Prism", seconds: 50)])
        #expect(found.first?.seconds == 60)
    }

    @Test func aiChatSuggestionNamesItsMacApps() {
        let ai = PresetUpdates.suggestedCategories.first { $0.id == "ai-chat" }!
        let ids = Set(ai.apps.map(\.bundleID))
        #expect(ids.isSuperset(of: ["com.openai.chat", "com.openai.codex", "com.google.GeminiMacOS",
                                    "com.google.antigravity", "ai.opencode.desktop"]))
        #expect(ai.websites.contains("chatgpt.com"))
        #expect(FocusCategory.presets.first { $0.id == "ai-chat" }?.apps == ai.apps)
    }
}
