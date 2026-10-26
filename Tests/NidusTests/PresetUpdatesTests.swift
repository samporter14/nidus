import Testing
@testable import Nidus

struct PresetUpdatesTests {
    static func category(_ id: String, _ sites: [String]) -> FocusCategory {
        FocusCategory(id: id, name: id, symbol: "newspaper", apps: [], websites: sites)
    }

    @Test func aSavedNewsCategoryGainsTheMissingSitesOnceAndKeepsEverythingElse() {
        let saved = [Self.category("social", ["x.com"]), Self.category("news", ["cnn.com", "my-own-blog.example"])]
        let updated = PresetUpdates.applying(to: saved, since: 0)
        let news = updated.first { $0.id == "news" }!
        #expect(news.websites.prefix(2) == ["cnn.com", "my-own-blog.example"], "what was there stays, in order")
        #expect(news.websites.contains("reuters.com") && news.websites.contains("apnews.com"))
        #expect(news.websites.filter { $0 == "cnn.com" }.count == 1, "no duplicates")
        #expect(updated.first { $0.id == "social" } == saved[0], "other categories are untouched")
    }

    @Test func aSiteTheyRemovedStaysRemovedOnceTheVersionIsRecorded() {
        let saved = [Self.category("news", ["cnn.com"])]
        #expect(PresetUpdates.applying(to: saved, since: PresetUpdates.currentVersion) == saved)
    }

    @Test func theirOwnNewsCategoryAndAMissingPresetAreLeftAlone() {
        let own = Self.category("43E119B2-7171-4928-AF2D-886A78423F75", ["nytimes.com"])
        #expect(PresetUpdates.applying(to: [own], since: 0) == [own])
        #expect(PresetUpdates.applying(to: [], since: 0).isEmpty, "a deleted News is not brought back")
    }

    @Test func aFreshInstallAlreadyHasTheWholeList() {
        let news = FocusCategory.presets.first { $0.id == "news" }!
        #expect(Set(PresetUpdates.newsSites).isSubset(of: Set(news.websites)))
        #expect(Set(news.websites).count == news.websites.count, "no site listed twice")
    }

    @Test func everyAddedSiteIsAValidWebsiteRule() {
        for site in PresetUpdates.newsSites { #expect(WebsiteEntry(typed: site) != nil, "\(site)") }
    }
}
