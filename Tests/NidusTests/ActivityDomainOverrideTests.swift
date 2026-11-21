import Foundation
import Testing
@testable import Nidus

private let chrome = "com.google.Chrome"

struct ActivityDomainOverrideTests {
    let work = FocusCategory.workSeed
    let research = FocusCategory(id: "research", name: "Research", symbol: "circle", apps: [], websites: ["scholar.google.com"])

    private func categorizer(_ overrides: ActivityOverrides, _ categories: [FocusCategory] = []) -> ActivityCategorizer {
        ActivityCategorizer(categories: categories, work: work, overrides: overrides)
    }

    @Test func registrableDomains() {
        #expect(ActivityDomain.registrable(of: "docs.google.com") == "google.com")
        #expect(ActivityDomain.registrable(of: "google.com") == "google.com")
        #expect(ActivityDomain.registrable(of: "a.b.example.org") == "example.org")
        #expect(ActivityDomain.registrable(of: "news.bbc.co.uk") == "bbc.co.uk")
        #expect(ActivityDomain.registrable(of: "bbc.co.uk") == "bbc.co.uk")
        #expect(ActivityDomain.registrable(of: "localhost") == nil)
        #expect(ActivityDomain.registrable(of: "10.0.0.1") == nil)
    }

    @Test func aDomainOverrideCoversSubdomainsAndTheDomainItself() {
        var overrides = ActivityOverrides()
        overrides.set(.work, subject: .domain("google.com"), name: "google.com and subdomains")
        let c = categorizer(overrides)
        #expect(c.category(appID: chrome, site: "docs.google.com", url: "https://docs.google.com/document/d/1") == "work")
        #expect(c.category(appID: chrome, site: "google.com", url: "https://www.google.com/search") == "work")
        #expect(c.category(appID: chrome, site: "a.b.google.com", url: "https://a.b.google.com/") == "work")
        #expect(c.category(appID: chrome, site: "notgoogle.com", url: "https://notgoogle.com/") == nil)
        #expect(c.category(appID: chrome, site: "google.com.evil.io", url: "https://google.com.evil.io/") == nil)
    }

    @Test func anExactHostOverrideWinsOverTheDomain() {
        var overrides = ActivityOverrides()
        overrides.set(.work, subject: .domain("google.com"), name: "google.com and subdomains")
        overrides.set(.category("research"), subject: .site("scholar.google.com"), name: "scholar.google.com")
        let c = categorizer(overrides, [research])
        #expect(c.category(appID: chrome, site: "scholar.google.com", url: "https://scholar.google.com/") == "research")
        #expect(c.category(appID: chrome, site: "mail.google.com", url: "https://mail.google.com/") == "work")
        // An exact host set to Uncategorized beats the domain too.
        overrides.set(.uncategorized, subject: .site("mail.google.com"), name: "mail.google.com")
        #expect(categorizer(overrides, [research]).category(appID: chrome, site: "mail.google.com", url: "https://mail.google.com/") == nil)
    }

    @Test func aSiteOverrideStaysExactHost() {
        var overrides = ActivityOverrides()
        overrides.set(.work, appID: chrome, site: "google.com", url: "https://google.com/")
        #expect(overrides.sites["google.com"] != nil)
        #expect(categorizer(overrides).category(appID: chrome, site: "docs.google.com", url: "https://docs.google.com/") == nil)
    }

    @Test func oldSavedOverridesDecodeAsExactHost() throws {
        let old = #"{"apps":{"com.x.App":{"group":"work","name":"X"}},"sites":{"google.com":{"group":"category:research","name":"google.com"}}}"#
        let decoded = try JSONDecoder().decode(ActivityOverrides.self, from: Data(old.utf8))
        #expect(decoded.apps["com.x.App"]?.group == .work)
        #expect(decoded.sites["google.com"]?.group == .category("research"))
        #expect(decoded.domains.isEmpty && decoded.pages.isEmpty)
        #expect(categorizer(decoded, [research]).category(appID: chrome, site: "docs.google.com", url: "https://docs.google.com/") == nil)
    }

    @Test func newOverridesRoundTrip() throws {
        var overrides = ActivityOverrides()
        overrides.set(.work, subject: .domain("google.com"), name: "google.com and subdomains")
        overrides.set(.category("research"), subject: .page(.local), name: "Local and browser pages")
        let back = try JSONDecoder().decode(ActivityOverrides.self, from: JSONEncoder().encode(overrides))
        #expect(back == overrides)
        #expect(back.items.count == 2)
        #expect(!back.isEmpty && back.countsAnythingAsWork)
    }

    @Test func removingAndMovingCategoriesReachDomainsAndPages() {
        var overrides = ActivityOverrides()
        overrides.set(.category("a"), subject: .domain("google.com"), name: "g")
        overrides.set(.category("a"), subject: .page(.science), name: "s")
        overrides.moveCategory("a", to: "b")
        #expect(overrides.domains["google.com"]?.group == .category("b"))
        #expect(overrides.pages["science"]?.group == .category("b"))
        overrides.removeCategory("b")
        #expect(overrides.isEmpty)
        overrides.set(.work, subject: .page(.local), name: "x")
        overrides.remove(.page(.local))
        #expect(overrides.isEmpty)
    }
}
