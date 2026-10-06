//
//  BlockingRulesTests.swift
//  NidusTests
//
//  The pure parts of the blockers: which URLs and apps are caught, and the
//  block page's round trip. The Apple Event side is covered by the spike,
//  against real browsers.
//

import Foundation
import Testing
@testable import Nidus

struct DomainMatcherTests {
    let matcher = DomainMatcher(["youtube.com", "News.YCombinator.com.", " reddit.com "])

    @Test(arguments: [
        "https://youtube.com/watch?v=1",
        "https://www.youtube.com/",
        "http://m.youtube.com",
        "https://news.ycombinator.com/item?id=1",
        "https://old.reddit.com/r/swift",
        "HTTPS://WWW.YOUTUBE.COM/",
    ])
    func blocks(_ url: String) {
        #expect(matcher.matches(url))
    }

    @Test(arguments: [
        "https://notyoutube.com/",
        "https://youtube.com.evil.example/",
        "https://ycombinator.com/",
        "file:///Users/me/youtube.com.html",
        "about:blank",
        "not a url",
    ])
    func allows(_ url: String) {
        #expect(!matcher.matches(url))
    }
}

struct BlockPageTests {
    let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/Focus Test"))

    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "https://example.com/a b/ünïcode?q=1+2&x=%2F#frag",
        "https://news.ycombinator.com/",
    ])
    func roundTripsTheOriginalURL(_ original: String) {
        let blocked = page.url(blocking: original, goal: "Ship it & #win = done", snoozeMinutes: 5, snoozeKey: "youtube.com")
        #expect(blocked.hasPrefix("file:///tmp/Focus%20Test/blocked.html?g="))
        #expect(!blocked.contains("#"), "a raw # would cut the query off at the fragment")
        #expect(page.original(from: blocked) == original)
        let items = URLComponents(string: blocked)?.queryItems ?? []
        #expect(items.first { $0.name == "g" }?.value == "Ship it & #win = done")
        #expect(items.first { $0.name == "s" }?.value == "youtube.com")
        #expect(items.first { $0.name == "m" }?.value == "5")
    }

    @Test func ignoresOtherURLs() {
        #expect(page.original(from: "https://youtube.com/") == nil)
        #expect(page.original(from: "file:///tmp/Focus%20Test/other.html?u=x") == nil)
        #expect(page.original(from: "https://evil.example/tmp/Focus%20Test/blocked.html?u=x") == nil)
    }

    @Test func installWritesThePageWithTheSnoozeLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = BlockPage(directory: dir, dropletID: "focus")
        try page.install()
        let html = try String(contentsOf: page.fileURL, encoding: .utf8)
        #expect(html.contains("nidus://snooze?site="))
        #expect(!html.contains("{{DROPLET}}"))
    }
}

struct WebsiteRuleTests {
    @Test func blockModeSnoozesTheEntryThatMatched() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com"])
        #expect(rule.blocks("https://m.youtube.com/"))
        #expect(rule.snoozeKey(for: "https://m.youtube.com/watch") == "youtube.com")
    }

    @Test func allowModeBlocksEveryOtherWebPageOnly() {
        let rule = WebsiteRule(mode: .allow, domains: ["developer.apple.com"])
        #expect(!rule.blocks("https://developer.apple.com/documentation"))
        #expect(rule.blocks("https://www.youtube.com/"))
        #expect(rule.snoozeKey(for: "https://www.youtube.com/") == "youtube.com")
        #expect(!rule.blocks("about:blank"), "browser pages are never blocked")
        #expect(!rule.blocks("file:///Users/me/notes.html"))
    }
}

struct CategoryTests {
    @Test(arguments: [
        ("youtube.com", "youtube.com"),
        // A path is kept now (a rule can block part of a site): the query still goes.
        ("  https://www.YouTube.com/watch?v=1 ", "youtube.com/watch"),
        ("news.ycombinator.com/", "news.ycombinator.com"),
        ("http://bbc.co.uk", "bbc.co.uk"),
    ])
    func normalisesTypedDomains(_ input: String, _ expected: String) {
        #expect(FocusCategory.domain(from: input) == expected)
    }

    @Test(arguments: ["", "   ", "localhost", "not a domain", ".com"])
    func rejectsWhatIsNotADomain(_ input: String) {
        #expect(FocusCategory.domain(from: input) == nil)
    }

    @Test func aPlanMergesCategoriesWithoutDuplicates() {
        let a = FocusCategory(id: "a", name: "A", symbol: "circle",
                              apps: [BlockedApp(bundleID: "x", name: "X")], websites: ["one.com", "two.com"])
        let b = FocusCategory(id: "b", name: "B", symbol: "circle",
                              apps: [BlockedApp(bundleID: "x", name: "X"), BlockedApp(bundleID: "y", name: "Y")],
                              websites: ["two.com"])
        let plan = SessionPlan(goal: "", duration: 60, mode: .block, categories: [a, b], reopensQuitApps: false)
        #expect(plan.apps == ["x", "y"])
        #expect(plan.websites == ["one.com", "two.com"])
    }

    @Test func presetsAreUsable() {
        #expect(Set(FocusCategory.presets.map(\.id)).count == FocusCategory.presets.count)
        for preset in FocusCategory.presets {
            #expect(!preset.isEmpty)
            for site in preset.websites { #expect(FocusCategory.domain(from: site) == site, "\(site) is not normalised") }
        }
        #expect(FocusCategory.defaultSelection.allSatisfy { id in FocusCategory.presets.contains { $0.id == id } })
    }
}

@MainActor
struct AppBlockerRuleTests {
    @Test func blockModeBlocksOnlyTheList() {
        let blocker = AppBlocker(mode: .block(["com.tinyspeck.slackmacgap"]), action: .hide)
        #expect(blocker.isBlocked("com.tinyspeck.slackmacgap"))
        #expect(!blocker.isBlocked("com.apple.Safari"))
    }

    @Test func allowModeBlocksEverythingElseButNeverTheSystem() {
        let blocker = AppBlocker(mode: .allow(["com.apple.dt.Xcode"]), action: .hide)
        #expect(!blocker.isBlocked("com.apple.dt.Xcode"))
        #expect(blocker.isBlocked("com.tinyspeck.slackmacgap"))
        for exempt in ["com.apple.finder", "iordv.Droppy", "iordv.DroppyPlayground", "com.apple.systempreferences"] {
            #expect(!blocker.isBlocked(exempt), "\(exempt) must never be quit")
        }
    }

    @Test func exemptionsWinEvenWhenListed() {
        let blocker = AppBlocker(mode: .block(["com.apple.finder"]), action: .terminate)
        #expect(!blocker.isBlocked("com.apple.finder"))
    }
}
