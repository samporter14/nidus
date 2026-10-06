//
//  WebsitePathTests.swift
//  NidusTests
//
//  Website rules with a path: `youtube.com/shorts` blocks that part of a site.
//  Everything here is a pure function of a rule and a URL; no browser is ever
//  asked. The cases are the ones that would quietly leave a site unblocked
//  (or block one it should not) if the matching were off by a segment.
//

import Foundation
import JavaScriptCore
import Testing
@testable import Nidus

private func blocked(_ rules: [String], _ url: String, mode: WebsiteRule.Mode = .block) -> Bool {
    WebsiteRule(mode: mode, domains: rules).blocks(url)
}

// MARK: - Matching

struct PathMatchingTests {
    /// (rule, url, whether a block-mode rule catches it)
    @Test(arguments: [
        // A rule without a path is the domain it always was.
        ("youtube.com", "https://youtube.com/shorts/abc", true),
        ("youtube.com", "https://www.youtube.com/watch?v=1", true),
        ("youtube.com", "https://m.youtube.com", true),
        ("youtube.com", "https://notyoutube.com/shorts", false),
        ("youtube.com", "https://youtube.com.evil.example/shorts", false),
        // The host of a path rule matches exactly as before, subdomains included.
        ("youtube.com/shorts", "https://youtube.com/shorts", true),
        ("youtube.com/shorts", "https://www.youtube.com/shorts", true),
        ("youtube.com/shorts", "https://m.youtube.com/shorts/abc", true),
        ("youtube.com/shorts", "https://notyoutube.com/shorts", false),
        ("youtube.com/shorts", "https://youtube.com.evil.example/shorts", false),
        ("youtube.com/shorts", "https://evil.example/youtube.com/shorts", false),
        // The path matches whole segments, from the start.
        ("youtube.com/shorts", "https://youtube.com/shorts/", true),
        ("youtube.com/shorts", "https://youtube.com/shorts/abc", true),
        ("youtube.com/shorts", "https://youtube.com/shorts/abc/def", true),
        ("youtube.com/shorts", "https://youtube.com/shortsfoo", false),
        ("youtube.com/shorts", "https://youtube.com/short", false),
        ("youtube.com/shorts", "https://youtube.com/watch?v=shorts", false),
        ("youtube.com/shorts", "https://youtube.com/channel/shorts", false),
        ("youtube.com/shorts", "https://youtube.com/", false),
        ("youtube.com/shorts", "https://youtube.com", false),
        ("reddit.com/r/all", "https://www.reddit.com/r/all", true),
        ("reddit.com/r/all", "https://old.reddit.com/r/all/top/?t=week", true),
        ("reddit.com/r/all", "https://reddit.com/r/allthethings", false),
        ("reddit.com/r/all", "https://reddit.com/r/swift", false),
        ("reddit.com/r/all", "https://reddit.com/r", false),
        ("x.com/explore", "https://x.com/explore", true),
        ("x.com/explore", "https://x.com/explore/tabs/for-you", true),
        ("x.com/explore", "https://x.com/home", false),
        ("x.com/explore", "https://x.com/exploration", false),
        // Hosts and paths compare without regard to case.
        ("youtube.com/shorts", "HTTPS://WWW.YOUTUBE.COM/SHORTS/AbC", true),
        ("YouTube.com/Shorts", "https://youtube.com/shorts", true),
        // Trailing and doubled slashes make no difference, on either side.
        ("youtube.com/shorts/", "https://youtube.com/shorts", true),
        ("youtube.com/shorts", "https://youtube.com//shorts//abc", true),
        ("youtube.com//shorts//", "https://youtube.com/shorts/abc", true),
        // Only the host and path count: not the query, the fragment, a port or a login.
        ("youtube.com/shorts", "https://youtube.com/shorts?feature=share", true),
        ("youtube.com/shorts", "https://youtube.com/shorts#top", true),
        ("youtube.com/shorts", "https://youtube.com:8443/shorts", true),
        ("youtube.com/shorts", "https://me:pw@youtube.com/shorts", true),
        ("youtube.com/shorts", "https://youtube.com/?next=/shorts", false),
        ("youtube.com/shorts", "https://youtube.com/watch#/shorts", false),
        // Ways round it: the same page written another way.
        ("youtube.com/shorts", "https://youtube.com/%73horts", true),
        ("youtube.com/shorts", "https://youtube.com/%53HORTS/abc", true),
        ("youtube.com/shorts", "https://youtube.com/watch/../shorts", true),
        ("youtube.com/shorts", "https://youtube.com./shorts", true),
        ("youtube.com", "https://youtube.com./", true),
        // Pages that are not the web are left alone.
        ("youtube.com/shorts", "file:///Users/me/youtube.com/shorts", false),
        ("youtube.com/shorts", "about:blank", false),
        ("youtube.com", "chrome://youtube.com/", false),
        ("youtube.com/shorts", "not a url", false),
    ])
    func blockMode(_ rule: String, _ url: String, _ expected: Bool) {
        #expect(blocked([rule], url) == expected, "\(rule) against \(url)")
    }

    @Test func aListMatchesWhenAnyEntryDoes() {
        let rules = ["youtube.com/shorts", "reddit.com/r/all", "news.ycombinator.com"]
        #expect(blocked(rules, "https://www.youtube.com/shorts/x"))
        #expect(blocked(rules, "https://reddit.com/r/all"))
        #expect(blocked(rules, "https://news.ycombinator.com/item?id=1"))
        #expect(!blocked(rules, "https://youtube.com/watch?v=1"))
        #expect(!blocked(rules, "https://reddit.com/r/swift"))
    }

    @Test func aPathIsNotAWildcardForTheHost() {
        // The reason a rule needs its host: `/shorts` alone is nothing.
        for rule in ["/shorts", "shorts", "", " ", ".", "///", "/", "com", "localhost", "?q=1", "https://", "ftp://youtube.com"] {
            for url in ["https://youtube.com/shorts", "https://com/", "https://localhost/", "https://example.com/shorts"] {
                #expect(!blocked([rule], url), "\"\(rule)\" must block nothing, but blocked \(url)")
            }
        }
        #expect(DomainMatcher(["/shorts", "", "com"]).domains.isEmpty)
    }

    @Test func anEmptyBlockListBlocksNothing() {
        #expect(!blocked([], "https://youtube.com/shorts"))
        #expect(!blocked([], "https://example.com/"))
    }

    @Test func theNarrowestEntryIsTheOneReported() {
        let matcher = DomainMatcher(["youtube.com", "youtube.com/shorts", "m.youtube.com"])
        #expect(matcher.matchedDomain("https://www.youtube.com/shorts/x") == "youtube.com/shorts")
        #expect(matcher.matchedDomain("https://m.youtube.com/watch") == "m.youtube.com", "more host beats less, as before")
        #expect(matcher.matchedDomain("https://www.youtube.com/watch") == "youtube.com")
        #expect(matcher.matchedDomain("https://m.youtube.com/shorts/x") == "youtube.com/shorts", "path first, then host")
        #expect(matcher.matchedDomain("https://example.com/") == nil)
    }

    @Test func entriesReadBackFromSavedDataKeepTheirOldMeaning() {
        // The forms the first versions matched.
        let matcher = DomainMatcher(["News.YCombinator.com.", " reddit.com ", "www.example.com"])
        #expect(matcher.matches("https://news.ycombinator.com/item?id=1"))
        #expect(matcher.matches("https://old.reddit.com/r/swift"))
        #expect(matcher.matches("https://www.example.com/"))
        #expect(!matcher.matches("https://m.example.com/"), "a saved www. is not widened to the site")
        #expect(DomainMatcher(["https://YouTube.com/Shorts/"]).matches("https://m.youtube.com/shorts/1"))
    }
}

// MARK: - Allow mode

struct AllowModePathTests {
    let rules = ["developer.apple.com", "github.com/samporter14"]

    @Test(arguments: [
        ("https://developer.apple.com/documentation/swiftui", true),
        ("https://docs.developer.apple.com/", true),
        ("https://github.com/samporter14", true),
        ("https://github.com/samporter14/nidus/issues/3?x=1", true),
        ("https://github.com/SamPorter14/Nidus", true),
        ("https://www.github.com/samporter14/nidus", true),
        // The pages above a path rule, and its neighbours, are not allowed.
        ("https://github.com/", false),
        ("https://github.com/other", false),
        ("https://github.com/samporter14x", false),
        ("https://github.com/orgs/samporter14", false),
        ("https://www.youtube.com/shorts", false),
        // Browser pages are never blocked in either mode.
        ("about:blank", true),
        ("file:///Users/me/notes.html", true),
        ("chrome://settings", true),
    ])
    func anyEntryAllowsAPage(_ url: String, _ allowed: Bool) {
        #expect(!blocked(rules, url, mode: .allow) == allowed, "\(url)")
    }

    @Test func aBareHostAlongsideAPathAllowsTheWholeSite() {
        let rules = ["github.com", "github.com/samporter14"]
        #expect(!blocked(rules, "https://github.com/other", mode: .allow))
        #expect(!blocked(rules, "https://github.com/samporter14/nidus", mode: .allow))
    }

    @Test func aPathOnlyAllowsThatPartOfAnOtherwiseBlockedSite() {
        let rules = ["youtube.com/watch"]
        #expect(!blocked(rules, "https://www.youtube.com/watch?v=1", mode: .allow))
        #expect(blocked(rules, "https://www.youtube.com/", mode: .allow))
        #expect(blocked(rules, "https://www.youtube.com/shorts/x", mode: .allow))
    }

    @Test func anEmptyAllowListBlocksEveryWebPageAndNothingElse() {
        #expect(blocked([], "https://example.com/", mode: .allow))
        #expect(!blocked([], "about:blank", mode: .allow))
    }

    @Test func snoozingInAllowModeLetsTheWholeSiteThrough() {
        let rule = WebsiteRule(mode: .allow, domains: rules)
        let key = rule.snoozeKey(for: "https://www.github.com/other/repo?tab=readme")
        #expect(key == "github.com", "the site itself: no listed path was this page's")
        // What the engine does with the key: it joins the allow list.
        let snoozed = WebsiteRule(mode: .allow, domains: rules + [key])
        #expect(!snoozed.blocks("https://github.com/other/repo"))
        #expect(!snoozed.blocks("https://github.com/"))
        #expect(snoozed.blocks("https://www.youtube.com/"))
    }
}

// MARK: - Normalising what is typed

struct NormaliseWebsiteTests {
    @Test(arguments: [
        // Bare domains, as before.
        ("youtube.com", "youtube.com"),
        ("  YouTube.COM  ", "youtube.com"),
        ("www.youtube.com", "youtube.com"),
        ("news.ycombinator.com/", "news.ycombinator.com"),
        ("http://bbc.co.uk", "bbc.co.uk"),
        // Addresses pasted from a browser.
        ("https://www.youtube.com/shorts/abc?feature=share#top", "youtube.com/shorts/abc"),
        ("https://www.youtube.com/shorts/", "youtube.com/shorts"),
        ("HTTPS://WWW.Reddit.com/R/All/?sort=top", "reddit.com/r/all"),
        ("//x.com/explore", "x.com/explore"),
        ("x.com/explore?lang=en", "x.com/explore"),
        ("youtube.com/shorts#top", "youtube.com/shorts"),
        ("https://youtube.com?x=1", "youtube.com"),
        ("https://youtube.com#top", "youtube.com"),
        ("youtube.com/watch?next=https://evil.example/x", "youtube.com/watch"),
        ("youtube.com:8080/shorts", "youtube.com/shorts"),
        // Paths are tidied.
        ("youtube.com//shorts///", "youtube.com/shorts"),
        ("youtube.com/a/./b/../shorts", "youtube.com/a/shorts"),
        ("youtube.com/../shorts", "youtube.com/shorts"),
        ("youtube.com/%73horts", "youtube.com/shorts"),
        ("youtube.com/%53HORTS", "youtube.com/shorts"),
        ("reddit.com/r/Ask Reddit", "reddit.com/r/ask%20reddit"),
        ("example.com/caf\u{e9}", "example.com/caf\u{e9}"),
        ("example.com/caf%C3%A9", "example.com/caf\u{e9}"),
        // International domains, typed either way.
        ("b\u{fc}cher.de/x", "b\u{fc}cher.de/x"),
        ("xn--bcher-kva.de/x", "b\u{fc}cher.de/x"),
    ])
    func normalises(_ input: String, _ expected: String) {
        #expect(FocusCategory.domain(from: input) == expected, "\"\(input)\"")
    }

    @Test(arguments: [
        "", "   ", "\n",
        "localhost", "not a domain", ".com", "com", "www.com", "youtube", "youtube..com", "-bad.com", "bad-.com", "youtube.com.",
        "/shorts", "/", "?q=1", "#top", "http://", "https://",
        "ftp://youtube.com", "file:///Users/me/a.html", "chrome://settings", "about:blank", "javascript:alert(1)",
        "mailto:me@example.com", "me@example.com", "https://me:pw@example.com/x",
        "example.com:port/x", "[::1]/x", "exa mple.com/x", "exam<ple>.com",
    ])
    func rejectsGarbage(_ input: String) {
        #expect(FocusCategory.domain(from: input) == nil, "\"\(input)\" should be refused")
    }

    @Test(arguments: [
        "youtube.com", "youtube.com/shorts", "reddit.com/r/all", "x.com/explore", "example.com/a/b/c",
        "reddit.com/r/ask%20reddit", "example.com/100%25", "example.com/a%2Fb", "example.com/what%3F", "example.com/a%23b",
        "example.com/caf\u{e9}", "b\u{fc}cher.de/x", "xn--bcher-kva.de",
    ])
    func aRuleReadBackIsTheSameRule(_ rule: String) throws {
        // The Snooze link hands the rule back through this, and the engine
        // finds it in the plan by exact text.
        let once = try #require(FocusCategory.domain(from: rule))
        #expect(FocusCategory.domain(from: once) == once)
        #expect(WebsiteEntry(stored: once)?.text == once)
    }

    @Test func everyPresetStaysAsItWas() {
        for preset in FocusCategory.presets {
            for site in preset.websites {
                #expect(FocusCategory.domain(from: site) == site)
                #expect(WebsiteEntry(stored: site)?.text == site)
                #expect(WebsiteEntry(stored: site)?.segments.isEmpty == true)
            }
        }
    }
}

// MARK: - Snoozing and stats

struct PathSnoozeTests {
    let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/Focus Test"))

    @Test func theKeyIsTheRuleThatCaughtThePage() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts", "reddit.com", "x.com/explore"])
        #expect(rule.snoozeKey(for: "https://www.youtube.com/shorts/abc?feature=share") == "youtube.com/shorts")
        #expect(rule.snoozeKey(for: "https://m.youtube.com/shorts") == "youtube.com/shorts")
        #expect(rule.snoozeKey(for: "https://old.reddit.com/r/swift") == "reddit.com", "no path in the rule, none in the key")
        #expect(rule.snoozeKey(for: "https://x.com/explore/tabs/trending") == "x.com/explore")
    }

    @Test func whereRulesOverlapTheKeyIsTheNarrowest() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com", "youtube.com/shorts"])
        #expect(rule.snoozeKey(for: "https://youtube.com/shorts/abc") == "youtube.com/shorts")
        #expect(rule.snoozeKey(for: "https://youtube.com/watch?v=1") == "youtube.com")
    }

    @Test func snoozingAPathRuleLetsOnlyThatPartThrough() {
        // Plan: just the path rule. The engine drops the snoozed key from the list.
        let rule = WebsiteRule(mode: .block, domains: [], snoozed: ["youtube.com/shorts"])
        #expect(!rule.blocks("https://youtube.com/shorts/abc"))

        // Plan: the path rule and another site. Only the path rule is snoozed.
        let both = WebsiteRule(mode: .block, domains: ["youtube.com/watch"], snoozed: ["youtube.com/shorts"])
        #expect(!both.blocks("https://youtube.com/shorts/abc"))
        #expect(both.blocks("https://youtube.com/watch?v=1"), "a snooze of shorts is not a snooze of watch")
        #expect(!both.blocks("https://youtube.com/"), "the home page was never listed")
    }

    @Test func snoozingWhereRulesOverlapStillLetsThePageThrough() {
        // Plan: youtube.com and youtube.com/shorts. The page was caught by
        // the narrowest; dropping that one alone would leave youtube.com
        // blocking it and the Snooze would seem to do nothing.
        let shorts = WebsiteRule(mode: .block, domains: ["youtube.com"], snoozed: ["youtube.com/shorts"])
        #expect(!shorts.blocks("https://youtube.com/shorts/abc"))
        #expect(!shorts.blocks("https://m.youtube.com/shorts"))
        #expect(shorts.blocks("https://youtube.com/watch?v=1"), "the rest of the site stays blocked")

        // Snoozing the whole site lets its shorts through as well.
        let site = WebsiteRule(mode: .block, domains: ["youtube.com/shorts"], snoozed: ["youtube.com"])
        #expect(!site.blocks("https://youtube.com/shorts/abc"))
        #expect(!site.blocks("https://youtube.com/watch"))
        #expect(!site.blocks("https://reddit.com/"), "and reddit.com was never listed")
    }

    @Test func aSnoozeOfSomethingElseChangesNothing() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts"], snoozed: ["com.tinyspeck.slackmacgap", "reddit.com"])
        #expect(rule.blocks("https://youtube.com/shorts/abc"))
    }

    @Test func theBlockPageCarriesTheRuleBackForTheSnoozeLink() throws {
        let original = "https://www.youtube.com/shorts/abc?feature=share"
        let blocked = page.url(blocking: original, goal: "Write", snoozeMinutes: 3, snoozeKey: "youtube.com/shorts")
        #expect(page.original(from: blocked) == original)
        #expect(!blocked.contains("youtube.com/shorts&"), "the key's slash is encoded, not left to end the value")
        let key = try #require(URLComponents(string: blocked)?.queryItems?.first { $0.name == "s" }?.value)
        #expect(key == "youtube.com/shorts")

        // What the page's script builds, and what the nidus:// handler does with it.
        let link = "nidus://snooze?site=" + key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let site = try #require(URLComponents(string: link)?.queryItems?.first { $0.name == "site" }?.value)
        #expect(FocusCategory.domain(from: site) == "youtube.com/shorts")
    }

    @MainActor
    @Test func theEngineSnoozesAndCountsByRuleText() throws {
        let h = Harness()
        h.engine.start(plan(25, apps: [], websites: ["youtube.com/shorts", "reddit.com/r/all"]))
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts", "reddit.com/r/all"])
        let key = rule.snoozeKey(for: "https://m.youtube.com/shorts/abc")

        h.engine.recordBlock(key, name: key)
        h.engine.recordBlock(key, name: key)
        h.engine.snooze(key)
        #expect(h.engine.session?.blocks == ["youtube.com/shorts": 2])
        #expect(h.engine.session?.names["youtube.com/shorts"] == "youtube.com/shorts")
        #expect(h.engine.enforcement?.websites == ["reddit.com/r/all"], "only shorts is let through")
        #expect(h.events.last == .snoozed("youtube.com/shorts"))

        h.clock.advance(3 * minute + 1)
        h.engine.tick()
        #expect(h.engine.enforcement?.websites == ["youtube.com/shorts", "reddit.com/r/all"])
        #expect(h.events.last == .snoozeEnded("youtube.com/shorts"))
    }

    @MainActor
    @Test func mostBlockedShowsTheRuleText() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entry = SessionEntry(start: start, end: start.addingTimeInterval(1800), focused: 1800, planned: 1800, outcome: .completed,
                                 blocks: ["youtube.com/shorts": 4, "youtube.com": 1],
                                 names: ["youtube.com/shorts": "youtube.com/shorts", "youtube.com": "youtube.com"])
        let stats = FocusStats(sessions: [entry])
        #expect(stats.mostBlocked == .init(key: "youtube.com/shorts", name: "youtube.com/shorts", value: 4))
    }
}

// MARK: - Tabs: redirect and restore

struct PathTabTests {
    let blocker = BrowserBlocker(blockPage: BlockPage(directory: URL(fileURLWithPath: "/tmp/Focus Test")))
    let tabs = [
        TabLocation(windowID: 1, index: 1, url: "https://www.youtube.com/shorts/abc?feature=share"),
        TabLocation(windowID: 1, index: 2, url: "https://www.youtube.com/watch?v=1"),
        TabLocation(windowID: 1, index: 3, url: "https://example.com/"),
        TabLocation(windowID: 2, index: 1, url: "about:blank"),
        TabLocation(windowID: 2, index: 2, url: "https://m.youtube.com/shorts"),
    ]

    @Test func onlyTheTabsInsideThePathAreRedirected() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts"])
        let redirects = blocker.redirects(for: tabs, rule: rule, goal: "Write", snoozeMinutes: 3)
        #expect(redirects.map(\.tab) == [tabs[0], tabs[4]])
        #expect(redirects.map(\.key) == ["youtube.com/shorts", "youtube.com/shorts"])
        for redirect in redirects {
            #expect(redirect.page.hasPrefix("file:///tmp/Focus%20Test/blocked.html?"))
            #expect(blocker.blockPage.original(from: redirect.page) == redirect.tab.url, "the whole address, path and query, is kept")
        }
    }

    @Test func restoringPutsPathBlockedTabsBackOnTheirExactPage() {
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts"])
        // The browser after the sweep: blocked tabs now show the block page.
        let after = tabs.enumerated().map { offset, tab -> TabLocation in
            guard let redirect = blocker.redirects(for: [tab], rule: rule).first else { return tab }
            return TabLocation(windowID: tab.windowID, index: tab.index, url: redirect.page)
        }
        #expect(after[0].url != tabs[0].url)

        // The session ends: every block-page tab returns, and only those.
        let all = blocker.restorations(in: after)
        #expect(all.map(\.tab) == [after[0], after[4]])
        #expect(all.map(\.original) == [tabs[0].url, tabs[4].url])

        // A snooze of the path: the rule no longer blocks, so they return too.
        let snoozed = WebsiteRule(mode: .block, domains: [], snoozed: ["youtube.com/shorts"])
        #expect(blocker.restorations(in: after, keepBlocked: snoozed).map(\.original) == [tabs[0].url, tabs[4].url])

        // A snooze of something else: they stay put.
        let other = WebsiteRule(mode: .block, domains: ["youtube.com/shorts"])
        #expect(blocker.restorations(in: after, keepBlocked: other).isEmpty)
    }

    @Test func aSnoozeNarrowsWhatIsRestored() {
        // youtube.com blocked everything; snoozing its shorts rule puts back
        // the shorts tabs and leaves the watch page on the block page.
        let full = WebsiteRule(mode: .block, domains: ["youtube.com"])
        let after = blocker.redirects(for: tabs, rule: full).map {
            TabLocation(windowID: $0.tab.windowID, index: $0.tab.index, url: $0.page)
        }
        let narrowed = WebsiteRule(mode: .block, domains: ["youtube.com"], snoozed: ["youtube.com/shorts"])
        let back = blocker.restorations(in: after, keepBlocked: narrowed).map(\.original)
        #expect(back == [tabs[0].url, tabs[4].url])
    }

    @Test func allowModeRedirectsTheSiteAndRestoresIt() {
        let rule = WebsiteRule(mode: .allow, domains: ["github.com/samporter14"])
        let redirects = blocker.redirects(for: [
            TabLocation(windowID: 1, index: 1, url: "https://github.com/samporter14/nidus"),
            TabLocation(windowID: 1, index: 2, url: "https://github.com/other/repo"),
        ], rule: rule)
        #expect(redirects.map(\.tab.index) == [2])
        #expect(redirects.map(\.key) == ["github.com"])
        #expect(blocker.blockPage.original(from: redirects[0].page) == "https://github.com/other/repo")
    }
}

// MARK: - Block page

/// The page's own script, run in JavaScriptCore against a stand-in for the
/// few browser objects it touches, so what the page says is tested without a
/// browser: no window opens and nothing is navigated.
struct PathBlockPageTests {
    /// The script text of the page `install()` writes.
    static func script() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = BlockPage(directory: dir)
        try page.install()
        let html = try String(contentsOf: page.fileURL, encoding: .utf8)
        let start = try #require(html.range(of: "<script>"))
        let end = try #require(html.range(of: "</script>"))
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// What the page shows for a given query string.
    struct Shown {
        var text = "", title = "", snoozeHref = "", snoozeText = "", snoozeHidden = true, goal = "", goalHidden = true
    }

    static func show(query: String) throws -> Shown {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript("""
        const elements = {};
        const element = (id) => elements[id] ??= { hidden: true, textContent: id === "site" ? "This page is blocked until your session ends." : "", href: "" };
        var document = { title: "", getElementById: element };
        var location = { search: \(String(reflecting: query)) };
        class URLSearchParams {
          constructor(search) { this.map = {}; for (const pair of search.replace(/^\\?/, "").split("&")) {
            const i = pair.indexOf("="); if (i > 0) this.map[pair.slice(0, i)] = decodeURIComponent(pair.slice(i + 1)); } }
          get(name) { return name in this.map ? this.map[name] : null; }
        }
        class URL {
          constructor(text) { const m = /^[a-z]+:\\/\\/([^\\/?#:]+)/i.exec(text || ""); if (!m) throw new TypeError("Invalid URL"); this.hostname = m[1].toLowerCase(); }
        }
        """)
        context.evaluateScript(try script())
        #expect(failure == nil, "\(failure ?? "")")
        func read(_ expression: String) -> JSValue? { context.evaluateScript(expression) }
        var shown = Shown()
        shown.text = read("element('site').textContent")?.toString() ?? ""
        shown.title = read("document.title")?.toString() ?? ""
        shown.snoozeHref = read("element('snooze').href")?.toString() ?? ""
        shown.snoozeText = read("element('snooze').textContent")?.toString() ?? ""
        shown.snoozeHidden = read("element('snooze').hidden")?.toBool() ?? true
        shown.goal = read("element('goal-text').textContent")?.toString() ?? ""
        shown.goalHidden = read("element('goal').hidden")?.toBool() ?? true
        return shown
    }

    private let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/Focus Test"))

    @Test func aPathRuleIsNamedWithItsPathAndSnoozedByThatRule() throws {
        let url = page.url(blocking: "https://www.youtube.com/shorts/abc?feature=share", goal: "Write", snoozeMinutes: 3, snoozeKey: "youtube.com/shorts")
        let query = String(url[url.firstIndex(of: "?")!...])
        let shown = try Self.show(query: query)
        #expect(shown.text == "youtube.com/shorts is blocked until your session ends.")
        #expect(shown.title == "youtube.com/shorts is blocked")
        #expect(shown.snoozeText == "Snooze for 3 minutes")
        #expect(!shown.snoozeHidden)
        #expect(shown.snoozeHref == "nidus://snooze?site=youtube.com%2Fshorts")
        #expect(shown.goal == "Write" && !shown.goalHidden)
    }

    @Test func aWholeSiteRuleIsNamedAsBefore() throws {
        let url = page.url(blocking: "https://m.youtube.com/watch?v=1", snoozeMinutes: 1, snoozeKey: "youtube.com")
        let shown = try Self.show(query: String(url[url.firstIndex(of: "?")!...]))
        #expect(shown.text == "youtube.com is blocked until your session ends.")
        #expect(shown.snoozeText == "Snooze for 1 minute")
        #expect(shown.snoozeHref == "nidus://snooze?site=youtube.com")
        #expect(shown.goalHidden)
    }

    @Test func withNoKeyThePageFallsBackToTheSiteWithoutWWW() throws {
        let shown = try Self.show(query: "?g=&m=3&s=&u=" + "https%3A%2F%2FWWW.Example.com%2Fa%2Fb")
        #expect(shown.text == "example.com is blocked until your session ends.")
        #expect(shown.snoozeHref == "nidus://snooze?site=example.com")
    }

    @Test func aStrictSessionHasNoSnoozeAndALostAddressChangesNothing() throws {
        let strict = try Self.show(query: "?m=0&s=youtube.com%2Fshorts&u=https%3A%2F%2Fyoutube.com%2Fshorts")
        #expect(strict.snoozeHidden)
        #expect(strict.text == "youtube.com/shorts is blocked until your session ends.")
        let lost = try Self.show(query: "?m=3&s=youtube.com%2Fshorts&u=")
        #expect(lost.text == "This page is blocked until your session ends.")
        #expect(lost.snoozeHidden)
    }

    @Test func theInstalledPageKeepsItsSnoozeLinkAndLoadsNothing() throws {
        let script = try Self.script()
        #expect(script.contains("nidus://snooze?site="))
        #expect(script.contains("q.get(\"s\")"))
    }
}

// MARK: - Saved data

struct SavedWebsiteDataTests {
    @Test func anOldCategoryDecodesAndBlocksAsBefore() throws {
        // As 0.1.x wrote it: plain domains.
        let json = """
        {"id":"video","name":"Video","symbol":"play.rectangle",
         "apps":[{"bundleID":"com.apple.TV","name":"TV"}],
         "websites":["youtube.com","netflix.com","News.YCombinator.com."]}
        """
        let category = try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
        #expect(category.websites == ["youtube.com", "netflix.com", "News.YCombinator.com."], "stored strings are not rewritten")
        let rule = WebsiteRule(mode: .block, domains: category.websites)
        #expect(rule.blocks("https://www.youtube.com/shorts/abc"))
        #expect(rule.blocks("https://m.youtube.com/"))
        #expect(rule.blocks("https://news.ycombinator.com/item?id=1"))
        #expect(!rule.blocks("https://example.com/"))
        #expect(rule.snoozeKey(for: "https://www.youtube.com/watch") == "youtube.com")
    }

    @Test func aCategoryWithPathsIsStillAListOfStrings() throws {
        let category = FocusCategory(id: "feeds", name: "Feeds", symbol: "circle", apps: [],
                                     websites: ["youtube.com/shorts", "reddit.com/r/all"])
        let data = try JSONEncoder().encode(category)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["websites"] as? [String] == ["youtube.com/shorts", "reddit.com/r/all"])
        #expect(try JSONDecoder().decode(FocusCategory.self, from: data) == category)
        #expect(category.summary == "2 websites")
    }

    @MainActor
    @Test func theFileVersionOneSavedStillLoadsAndBlocksTheSame() throws {
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(OlderFileTests.v1.utf8))
        let websites = try #require(record.session?.plan.websites)
        #expect(websites == ["youtube.com"])
        #expect(WebsiteRule(mode: .block, domains: websites).blocks("https://www.youtube.com/watch?v=1"))
    }

    @Test func aPlanWithPathsRoundTripsAndMergesWithoutDuplicates() throws {
        let a = FocusCategory(id: "a", name: "A", symbol: "circle", apps: [], websites: ["youtube.com/shorts", "youtube.com"])
        let b = FocusCategory(id: "b", name: "B", symbol: "circle", apps: [], websites: ["youtube.com/shorts", "reddit.com/r/all"])
        let plan = SessionPlan(goal: "", duration: 60, mode: .block, categories: [a, b], reopensQuitApps: false)
        #expect(plan.websites == ["youtube.com/shorts", "youtube.com", "reddit.com/r/all"])
        #expect(try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(plan)) == plan)
    }
}
