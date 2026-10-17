//
//  WebsiteExceptionTests.swift
//  NidusTests
//
//  Website exceptions: pages let through although a broader rule blocks them.
//  Everything here is a pure function of a rule, an exception and a URL; no
//  browser is asked and no session is really started. The cases are the ones
//  that would quietly let a page through that was never named (a lookalike
//  host, an encoded slash, another video) or quietly block one that was.
//

import Foundation
import Testing
@testable import Nidus

private func exact(_ address: String) -> WebsiteException { WebsiteException(kind: .exact, address: address) }
private func subtree(_ address: String) -> WebsiteException { WebsiteException(kind: .subtree, address: address) }

/// Whether a block-mode rule on `rules` with these exceptions blocks `url`.
private func blocked(_ url: String, rules: [String] = ["youtube.com"], except exceptions: [WebsiteException]) -> Bool {
    WebsiteRule(mode: .block, domains: rules, exceptions: exceptions).blocks(url)
}

/// Whether the exceptions alone let `url` through.
private func allows(_ exception: WebsiteException, _ url: String) -> Bool {
    WebsiteExceptionMatcher([exception]).allows(url)
}

// MARK: - Exact and subtree

struct ExactAndSubtreeTests {
    @Test func anExactExceptionLetsOnePageThroughAndNothingBelowIt() {
        let e = exact("youtube.com/watch?v=abc")
        #expect(allows(e, "https://www.youtube.com/watch?v=abc"))
        #expect(allows(e, "https://youtube.com/watch?v=abc"))
        #expect(!allows(e, "https://youtube.com/watch?v=abc/extra"))
        #expect(!allows(e, "https://youtube.com/watch/extra?v=abc"))
        #expect(!allows(e, "https://youtube.com/shorts?v=abc"))
        #expect(!allows(e, "https://youtube.com/"))
    }

    @Test func aSubtreeExceptionLetsThePathAndWhatIsBelowItThrough() {
        let e = subtree("youtube.com/@lab")
        #expect(allows(e, "https://www.youtube.com/@lab"))
        #expect(allows(e, "https://youtube.com/@lab/"))
        #expect(allows(e, "https://youtube.com/@lab/videos"))
        #expect(allows(e, "https://youtube.com/@lab/videos/2?sort=new"))
        #expect(!allows(e, "https://youtube.com/@labs"), "whole segments")
        #expect(!allows(e, "https://youtube.com/@other/@lab"))
        #expect(!allows(e, "https://youtube.com/"))
        #expect(!allows(e, "https://youtube.com/watch?v=abc"))
    }

    @Test func aSubtreeOnTheRootIsTheWholeHostAndNoSubdomain() {
        let e = subtree("youtube.com")
        #expect(allows(e, "https://youtube.com/anything/at/all"))
        #expect(allows(e, "https://www.youtube.com/"))
        #expect(!allows(e, "https://m.youtube.com/"))
    }

    @Test func aSubtreeIgnoresTheQuery() {
        let e = subtree("youtube.com/playlist?list=PL1")
        #expect(allows(e, "https://youtube.com/playlist?list=PL2"), "the query is not used by a subtree")
        #expect(e.rule?.address == "youtube.com/playlist")
    }

    @Test func exceptionsOnlyLetThroughWhatARuleBlocks() {
        // Nothing else listed: a page no rule blocks stays unblocked either way.
        #expect(!blocked("https://example.com/x", except: []))
        #expect(blocked("https://youtube.com/watch?v=abc", except: []))
        #expect(!blocked("https://youtube.com/watch?v=abc", except: [exact("youtube.com/watch?v=abc")]))
        #expect(blocked("https://youtube.com/watch?v=xyz", except: [exact("youtube.com/watch?v=abc")]))
    }

    @Test func severalExceptionsEachLetTheirOwnPageThrough() {
        let list = [exact("youtube.com/watch?v=abc"), exact("youtube.com/watch?v=def"), subtree("youtube.com/@lab")]
        #expect(!blocked("https://youtube.com/watch?v=abc", except: list))
        #expect(!blocked("https://youtube.com/watch?v=def", except: list))
        #expect(!blocked("https://youtube.com/@lab/videos", except: list))
        #expect(blocked("https://youtube.com/watch?v=ghi", except: list))
    }

    @Test func anExceptionBeatsEveryListedEntryThatCoversThePage() {
        let rules = ["youtube.com", "youtube.com/watch"]
        #expect(!blocked("https://youtube.com/watch?v=abc", rules: rules, except: [exact("youtube.com/watch?v=abc")]))
        #expect(blocked("https://youtube.com/watch?v=xyz", rules: rules, except: [exact("youtube.com/watch?v=abc")]))
    }
}

// MARK: - Resource-identifying queries

struct ExceptionQueryTests {
    private let video = exact("youtube.com/watch?v=abc")

    @Test func theNamedParameterMustHaveTheNamedValue() {
        #expect(allows(video, "https://youtube.com/watch?v=abc"))
        #expect(!allows(video, "https://youtube.com/watch?v=xyz"))
        #expect(!allows(video, "https://youtube.com/watch?v="))
        #expect(!allows(video, "https://youtube.com/watch?v=abcd"))
        #expect(!allows(video, "https://youtube.com/watch?v=ab"))
    }

    @Test func aMissingParameterIsBlocked() {
        #expect(!allows(video, "https://youtube.com/watch"))
        #expect(!allows(video, "https://youtube.com/watch?list=PL1"))
        #expect(!allows(video, "https://youtube.com/watch?V=abc"), "names are not case-folded")
    }

    @Test func otherParametersAreIgnored() {
        #expect(allows(video, "https://youtube.com/watch?v=abc&t=30s"))
        #expect(allows(video, "https://youtube.com/watch?t=30s&v=abc&list=PL1&index=2"))
        #expect(allows(video, "https://youtube.com/watch?si=xyz&v=abc&feature=share"))
        #expect(allows(video, "https://youtube.com/watch?v=abc#t=30"), "a fragment is never compared")
    }

    @Test func valuesAreCaseSensitive() {
        #expect(!allows(video, "https://youtube.com/watch?v=ABC"))
        #expect(!allows(exact("youtube.com/watch?v=AbC"), "https://youtube.com/watch?v=abc"))
        #expect(allows(exact("youtube.com/watch?v=AbC"), "https://youtube.com/watch?v=AbC"))
    }

    @Test func aRepeatedParameterMustCarryTheValueEveryTime() {
        #expect(!allows(video, "https://youtube.com/watch?v=abc&v=xyz"))
        #expect(!allows(video, "https://youtube.com/watch?v=xyz&v=abc"))
        #expect(allows(video, "https://youtube.com/watch?v=abc&v=abc"))
    }

    @Test func encodedQueriesAreReadBeforeTheyAreCompared() {
        #expect(allows(video, "https://youtube.com/watch?v=%61bc"))
        #expect(allows(video, "https://youtube.com/watch?%76=abc"))
        #expect(!allows(video, "https://youtube.com/watch?v=%2561bc"), "a second layer of encoding stays encoded")
        #expect(allows(exact("search.example.com/find?q=a+b"), "https://search.example.com/find?q=a%20b"))
        #expect(allows(exact("search.example.com/find?q=a%2Bb"), "https://search.example.com/find?q=a%2Bb"))
        #expect(!allows(exact("search.example.com/find?q=a%2Bb"), "https://search.example.com/find?q=a+b"))
    }

    @Test func severalNamedParametersAreAllRequired() {
        let e = exact("example.com/doc?id=7&rev=3")
        #expect(allows(e, "https://example.com/doc?rev=3&id=7"))
        #expect(!allows(e, "https://example.com/doc?id=7"))
        #expect(!allows(e, "https://example.com/doc?id=7&rev=4"))
        #expect(e.rule?.address == "example.com/doc?id=7&rev=3", "written in name order")
    }

    @Test func anExactExceptionWithNoQueryIgnoresTheWholeQuery() {
        let e = exact("example.com/paper")
        #expect(allows(e, "https://example.com/paper"))
        #expect(allows(e, "https://example.com/paper?anything=1"))
        #expect(!allows(e, "https://example.com/paper/2"))
    }
}

// MARK: - Encoding, case, slashes, ports

struct ExceptionNormalizationTests {
    @Test func percentEncodingIsUndoneOnceBeforeComparing() {
        let e = exact("example.com/papers/aims")
        #expect(allows(e, "https://example.com/papers/%61ims"))
        #expect(allows(e, "https://example.com/%70apers/aims"))
        #expect(!allows(e, "https://example.com/papers/%41ims"), "%41 is A, a different page")
        #expect(allows(exact("example.com/caf%C3%A9"), "https://example.com/caf%C3%A9"))
        #expect(allows(exact("example.com/café"), "https://example.com/caf%C3%A9"))
    }

    @Test func anEncodedSlashStaysInsideItsSegment() {
        let two = exact("example.com/a/b")
        #expect(!allows(two, "https://example.com/a%2Fb"), "one segment is not two")
        #expect(!allows(two, "https://example.com/a%2fb"))
        let one = exact("example.com/a%2Fb")
        #expect(allows(one, "https://example.com/a%2Fb"))
        #expect(!allows(one, "https://example.com/a/b"))
        // The slash does not let a subtree exception reach down either.
        #expect(!allows(subtree("example.com/a"), "https://example.com/a%2Fb"), "a%2Fb is its own segment, not under /a")
    }

    @Test func doubleEncodingStaysEncoded() {
        let e = exact("example.com/a/b")
        #expect(!allows(e, "https://example.com/a%252Fb"))
        #expect(!allows(exact("example.com/a%2Fb"), "https://example.com/a%252Fb"))
        #expect(allows(exact("example.com/a%252Fb"), "https://example.com/a%252Fb"))
        #expect(!allows(exact("example.com/shorts"), "https://example.com/%2573horts"), "%2573 is the text %73, not s")
    }

    @Test func dotSegmentsAreResolvedLikeABrowserWould() {
        let e = exact("example.com/papers/aims")
        #expect(allows(e, "https://example.com/papers/./aims"))
        #expect(allows(e, "https://example.com/other/../papers/aims"))
        #expect(allows(e, "https://example.com/papers/x/%2e%2e/aims"))
        #expect(!allows(e, "https://example.com/papers/aims/../other"))
    }

    @Test func theHostIgnoresCaseAndAWwwButThePathDoesNot() {
        let e = exact("YouTube.com/watch?v=abc")
        #expect(e.rule?.address == "youtube.com/watch?v=abc")
        #expect(allows(e, "HTTPS://WWW.YOUTUBE.COM/watch?v=abc"))
        #expect(allows(exact("www.youtube.com/watch?v=abc"), "https://youtube.com/watch?v=abc"))
        #expect(!allows(e, "https://youtube.com/Watch?v=abc"), "a path is case-sensitive: erring toward blocking")
        #expect(!allows(exact("example.com/Papers"), "https://example.com/papers"))
        #expect(allows(exact("example.com/Papers"), "https://example.com/Papers"))
    }

    @Test func onlyOneWwwIsDropped() {
        #expect(!allows(exact("youtube.com/x"), "https://www.www.youtube.com/x"))
        #expect(allows(exact("www.example.com/x"), "https://www.example.com/x"))
    }

    @Test func trailingSlashesAndTheTrailingDotMakeNoDifference() {
        let e = exact("example.com/papers/aims")
        #expect(allows(e, "https://example.com/papers/aims/"))
        #expect(allows(e, "https://example.com//papers//aims"))
        #expect(allows(exact("example.com/papers/aims/"), "https://example.com/papers/aims"))
        #expect(allows(e, "https://example.com./papers/aims"))
        #expect(allows(exact("example.com./papers/aims"), "https://example.com/papers/aims"))
        #expect(!allows(e, "https://example.com../papers/aims"), "one trailing dot, not two")
    }

    @Test func aNonStandardPortIsKeptAndMustMatch() {
        let e = exact("dev.example.com:8080/docs")
        #expect(e.rule?.address == "dev.example.com:8080/docs")
        #expect(allows(e, "http://dev.example.com:8080/docs"))
        #expect(allows(e, "https://dev.example.com:8080/docs"))
        #expect(!allows(e, "https://dev.example.com/docs"), "no port is another server")
        #expect(!allows(e, "https://dev.example.com:9090/docs"))
        #expect(!allows(exact("dev.example.com/docs"), "https://dev.example.com:8080/docs"))
    }

    @Test func theStandardPortsAreTheSameAsNone() {
        let e = exact("example.com/docs")
        #expect(allows(e, "https://example.com:443/docs"))
        #expect(allows(e, "http://example.com:80/docs"))
        #expect(!allows(e, "https://example.com:80/docs"), "80 is not the standard port of https")
        #expect(!allows(e, "http://example.com:443/docs"))
        #expect(exact("https://example.com:443/docs").rule?.address == "example.com/docs")
        #expect(exact("example.com:8080/docs").rule?.port == 8080)
    }

    @Test func aPortOutOfRangeIsNotAnAddress() {
        for address in ["example.com:0/x", "example.com:99999/x", "example.com:/x", "example.com:http/x"] {
            #expect(exact(address).rule == nil, "\(address)")
        }
    }

    @Test func textIsComparedAsBytes() {
        // A precomposed é against an e with a combining accent: different pages to a server.
        #expect(!allows(exact("example.com/caf\u{E9}"), "https://example.com/cafe%CC%81"))
        #expect(allows(exact("example.com/caf\u{E9}"), "https://example.com/caf%C3%A9"))
    }
}

// MARK: - Host boundaries

struct ExceptionHostTests {
    private let video = exact("youtube.com/watch?v=abc")

    @Test(arguments: [
        "https://notyoutube.com/watch?v=abc",
        "https://youtube.com.evil.example/watch?v=abc",
        "https://evil.example/watch?v=abc&u=youtube.com",
        "https://evil.example/?u=youtube.com/watch?v=abc",
        "https://evil.example/youtube.com/watch?v=abc",
        "https://youtube.com@evil.example/watch?v=abc",
        "https://youtube.com:pass@evil.example/watch?v=abc",
        "https://evil.example@youtube.com/watch?v=abc",
        "https://m.youtube.com/watch?v=abc",
        "https://music.youtube.com/watch?v=abc",
        "https://a.b.youtube.com/watch?v=abc",
        "https://youtube.co/watch?v=abc",
        "https://youtube.com.au/watch?v=abc",
        "https://xyoutube.com/watch?v=abc",
        "https://youtube-com.example/watch?v=abc",
    ])
    func lookalikeHostsAreNotCovered(_ url: String) {
        #expect(!allows(video, url))
        #expect(!allows(subtree("youtube.com"), url))
    }

    @Test func aSubdomainExceptionHasToSayItIsOne() {
        #expect(allows(exact("m.youtube.com/watch?v=abc"), "https://m.youtube.com/watch?v=abc"))
        #expect(!allows(exact("m.youtube.com/watch?v=abc"), "https://youtube.com/watch?v=abc"))
        #expect(!allows(exact("m.youtube.com/watch?v=abc"), "https://www.youtube.com/watch?v=abc"))
        #expect(blocked("https://m.youtube.com/watch?v=abc", except: [video]), "the rule covers m.youtube.com, the exception doesn't")
    }

    @Test func aLoginInAnAddressIsNeverLetThrough() {
        // The browser goes to youtube.com here, but an address with a login in it is not one to trust.
        #expect(!allows(video, "https://someone@youtube.com/watch?v=abc"))
        #expect(!allows(video, "https://someone:secret@youtube.com/watch?v=abc"))
        #expect(blocked("https://someone@youtube.com/watch?v=abc", except: [video]))
    }

    @Test func aLoginInTheExceptionIsRefused() {
        for address in ["someone@youtube.com/watch?v=abc", "youtube.com@evil.example/x", "https://a:b@youtube.com/x"] {
            #expect(exact(address).rule == nil, "\(address)")
            #expect(WebsiteException.draft(from: address, kind: .exact) == .failure(.notAWebAddress), "\(address)")
        }
    }

    @Test func aLookalikeInTheMiddleOfAnotherPageStaysBlockedUnderARealRule() {
        let rules = ["youtube.com", "evil.example"]
        #expect(blocked("https://evil.example/?u=youtube.com/watch?v=abc", rules: rules, except: [video]))
        #expect(blocked("https://youtube.com.evil.example/watch?v=abc", rules: rules, except: [video]))
        #expect(blocked("https://youtube.com@evil.example/watch?v=abc", rules: rules, except: [video]))
    }

    @Test(arguments: ["file:///Users/me/notes.html", "about:blank", "chrome://settings", "ftp://youtube.com/watch?v=abc",
                      "javascript:alert(1)", "data:text/html,youtube.com", "youtube.com/watch?v=abc", ""])
    func onlyHTTPAndHTTPSPagesAreEverLetThrough(_ url: String) {
        #expect(!allows(video, url))
        #expect(!allows(subtree("youtube.com"), url))
    }

    @Test(arguments: ["ftp://youtube.com/watch?v=abc", "chrome://settings", "file:///etc/hosts", "javascript:alert(1)",
                      "mailto:a@youtube.com", "data:text/html,x", "about:blank", "localhost", "/watch?v=abc", "", "   ",
                      "not a domain", ".com", "[::1]/x"])
    func anExceptionOnAnythingButAWebAddressIsRefused(_ address: String) {
        for kind in WebsiteException.Kind.choices {
            if case .success = WebsiteException.draft(from: address, kind: kind) { Issue.record("\(address) was accepted") }
            #expect(WebsiteException(kind: kind, address: address).rule == nil)
        }
    }

    @Test func anExceptionThatCannotBeReadLetsNothingThrough() {
        let broken = [exact("ftp://youtube.com/watch?v=abc"), exact(""), subtree("not a domain")]
        #expect(WebsiteExceptionMatcher(broken).isEmpty)
        #expect(blocked("https://youtube.com/watch?v=abc", except: broken))
    }

    @Test func aSchemeIsAcceptedAndDropped() {
        #expect(exact("https://www.YouTube.com/watch?v=abc").rule?.address == "youtube.com/watch?v=abc")
        #expect(exact("HTTP://youtube.com/watch?v=abc").rule?.address == "youtube.com/watch?v=abc")
        #expect(exact("//youtube.com/watch?v=abc").rule?.address == "youtube.com/watch?v=abc")
        #expect(allows(exact("https://youtube.com/watch?v=abc"), "http://youtube.com/watch?v=abc"), "the exception doesn't say which scheme")
    }
}

// MARK: - Redirects

struct ExceptionRedirectTests {
    private let blocker = BrowserBlocker(blockPage: BlockPage(directory: URL(fileURLWithPath: "/tmp/nidus-exception-test", isDirectory: true)))
    private let rule = WebsiteRule(mode: .block, domains: ["youtube.com"], exceptions: [exact("youtube.com/watch?v=abc")])

    private func redirected(_ url: String) -> Bool {
        !blocker.redirects(for: [TabLocation(windowID: 1, index: 1, url: url)], rule: rule).isEmpty
    }

    @Test func aPageIsJudgedAtTheAddressItIsOnNow() {
        // Sweep one: the allowed page. Sweep two, a second later: the same tab
        // redirected to another video. Nothing remembers the first.
        #expect(!redirected("https://youtube.com/watch?v=abc"))
        #expect(redirected("https://youtube.com/watch?v=xyz"))
        #expect(redirected("https://youtube.com/shorts/abc"))
        #expect(redirected("https://m.youtube.com/watch?v=abc"))
        // And back to the allowed one.
        #expect(!redirected("https://youtube.com/watch?v=abc&t=9"))
    }

    @Test func aRedirectToAnotherSiteIsJudgedByThatSiteAlone() {
        let both = WebsiteRule(mode: .block, domains: ["youtube.com", "reddit.com"], exceptions: [exact("youtube.com/watch?v=abc")])
        func sweeps(_ url: String) -> Bool { !blocker.redirects(for: [TabLocation(windowID: 1, index: 1, url: url)], rule: both).isEmpty }
        #expect(!sweeps("https://youtube.com/watch?v=abc"))
        #expect(sweeps("https://reddit.com/r/all"))
        #expect(sweeps("https://youtube.com/watch?v=abc.evil"), "a different video id")
    }

    @Test func eachTabOfOneSweepIsJudgedOnItsOwn() {
        let tabs = [TabLocation(windowID: 1, index: 1, url: "https://youtube.com/watch?v=abc"),
                    TabLocation(windowID: 1, index: 2, url: "https://youtube.com/watch?v=xyz"),
                    TabLocation(windowID: 2, index: 1, url: "https://youtube.com/watch?v=abc")]
        #expect(blocker.redirects(for: tabs, rule: rule).map(\.tab.index) == [2])
    }

    @Test func aBlockedPageReturnsOnlyIfItWasNeverBlockedAndOtherwiseOnItsOwnTerms() {
        // A tab on the block page is put back when the rule no longer blocks its original.
        let page = blocker.blockPage.url(blocking: "https://youtube.com/watch?v=abc", snoozeKey: "youtube.com")
        let tab = TabLocation(windowID: 1, index: 1, url: page)
        #expect(blocker.restorations(in: [tab], keepBlocked: rule).count == 1, "the original is excepted, so it may come back")
        let plain = WebsiteRule(mode: .block, domains: ["youtube.com"])
        #expect(blocker.restorations(in: [tab], keepBlocked: plain).isEmpty)
    }
}

// MARK: - Modes and snoozes

struct ExceptionModeTests {
    @Test func anAllowListIgnoresExceptions() {
        let rule = WebsiteRule(mode: .allow, domains: ["developer.apple.com"],
                               exceptions: [exact("youtube.com/watch?v=abc"), subtree("reddit.com")])
        #expect(rule.blocks("https://youtube.com/watch?v=abc"), "not on the allow list, so blocked, exception or not")
        #expect(rule.blocks("https://reddit.com/r/all"))
        #expect(!rule.blocks("https://developer.apple.com/documentation"))
        #expect(rule.blocks("https://www.youtube.com/") == WebsiteRule(mode: .allow, domains: ["developer.apple.com"]).blocks("https://www.youtube.com/"))
    }

    @Test func browserPagesAreStillNeverBlocked() {
        #expect(!blocked("about:blank", except: [exact("youtube.com/watch?v=abc")]))
        #expect(!blocked("file:///Users/me/notes.html", except: [exact("youtube.com/watch?v=abc")]))
    }

    @Test func aSnoozeLetsThroughWhatItCoversAndNoMoreThanItDid() {
        let list = [exact("youtube.com/watch?v=abc")]
        let snoozedShorts = WebsiteRule(mode: .block, domains: ["youtube.com"], snoozed: ["youtube.com/shorts"], exceptions: list)
        #expect(!snoozedShorts.blocks("https://youtube.com/shorts/1"), "the snooze still lets shorts through")
        #expect(snoozedShorts.blocks("https://youtube.com/watch?v=xyz"), "an exception doesn't widen a snooze: the rest stays blocked")
        #expect(!snoozedShorts.blocks("https://youtube.com/watch?v=abc"))
        let snoozedSite = WebsiteRule(mode: .block, domains: [], snoozed: ["youtube.com"], exceptions: list)
        #expect(!snoozedSite.blocks("https://youtube.com/anything"))
    }

    @Test func aSnoozeNeverWidensAnException() {
        // Snoozing the shorts entry doesn't let the watch page through.
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com/shorts", "youtube.com/watch"], snoozed: ["youtube.com/shorts"],
                               exceptions: [exact("youtube.com/watch?v=abc")])
        #expect(rule.blocks("https://youtube.com/watch?v=xyz"))
        #expect(!rule.blocks("https://youtube.com/watch?v=abc"))
        #expect(!rule.blocks("https://youtube.com/shorts/q"))
    }

    @Test func theSnoozeKeyIsTheSameWithOrWithoutExceptions() {
        let plain = WebsiteRule(mode: .block, domains: ["youtube.com", "youtube.com/shorts"])
        let withExceptions = WebsiteRule(mode: .block, domains: ["youtube.com", "youtube.com/shorts"],
                                         exceptions: [exact("youtube.com/watch?v=abc")])
        for url in ["https://m.youtube.com/watch?v=xyz", "https://youtube.com/shorts/1", "https://youtube.com/"] {
            #expect(withExceptions.snoozeKey(for: url) == plain.snoozeKey(for: url))
        }
        #expect(withExceptions.snoozeKey(for: "https://m.youtube.com/watch?v=xyz") == "youtube.com")
        #expect(withExceptions.snoozeKey(for: "https://youtube.com/shorts/1") == "youtube.com/shorts")
    }
}

// MARK: - Frozen in the plan

@MainActor
struct ExceptionPlanTests {
    @Test func theRunningRuleReadsTheExceptionsOfThePlanNotOfTheCategory() throws {
        var category = FocusCategory(id: "video", name: "Video", symbol: "play.rectangle", apps: [],
                                     websites: ["youtube.com"],
                                     websiteExceptions: [exact("youtube.com/watch?v=abc")])
        var plan = SessionPlan(goal: "", duration: 3600, mode: .block, categories: [category], reopensQuitApps: false)
        plan.websiteExceptions = category.websiteExceptions   // what startSession copies in
        let h = Harness()
        h.engine.start(plan)

        func runningRule() throws -> WebsiteRule {
            WebsiteRule(enforcement: try #require(h.engine.enforcement), session: h.engine.session)
        }
        #expect(try !runningRule().blocks("https://youtube.com/watch?v=abc"))
        #expect(try runningRule().blocks("https://youtube.com/watch?v=xyz"))

        // The category is edited mid-session, both ways. The running rule keeps the plan's.
        category.websiteExceptions = [exact("youtube.com/watch?v=xyz")]
        category.websites = []
        #expect(try !runningRule().blocks("https://youtube.com/watch?v=abc"))
        #expect(try runningRule().blocks("https://youtube.com/watch?v=xyz"), "a new exception waits for the next session")
        // The next session reads the category as it is then.
        var next = SessionPlan(goal: "", duration: 3600, mode: .block, categories: [category], reopensQuitApps: false)
        next.websiteExceptions = category.websiteExceptions
        #expect(next.websiteExceptions == [exact("youtube.com/watch?v=xyz")])
    }

    @Test func aStrictSessionKeepsExactlyTheExceptionsItStartedWith() throws {
        var plan = SessionPlan(goal: "", duration: 3600, mode: .block, apps: [], websites: ["youtube.com"])
        plan.strict = true
        plan.websiteExceptions = [exact("youtube.com/watch?v=abc")]
        let h = Harness()
        h.engine.start(plan)
        let before = WebsiteRule(enforcement: try #require(h.engine.enforcement), session: h.engine.session)
        // Time passes, and a relaunch restores the session from the saved plan.
        h.clock.advance(20 * minute)
        let (restored, _) = h.relaunch()
        let after = WebsiteRule(enforcement: try #require(restored.enforcement), session: restored.session)
        for url in ["https://youtube.com/watch?v=abc", "https://youtube.com/watch?v=xyz", "https://youtube.com/"] {
            #expect(before.blocks(url) == after.blocks(url), "\(url)")
        }
        #expect(!after.blocks("https://youtube.com/watch?v=abc"))
        #expect(after.blocks("https://youtube.com/watch?v=xyz"))
    }

    @Test func aSnoozeInTheEngineAndTheExceptionsOfThePlanWorkTogether() throws {
        var plan = SessionPlan(goal: "", duration: 3600, mode: .block, apps: [], websites: ["youtube.com", "reddit.com"])
        plan.websiteExceptions = [exact("youtube.com/watch?v=abc")]
        let h = Harness()
        h.engine.start(plan)
        h.engine.snooze("reddit.com")
        let rule = WebsiteRule(enforcement: try #require(h.engine.enforcement), session: h.engine.session)
        #expect(!rule.blocks("https://reddit.com/r/all"), "snoozed")
        #expect(rule.blocks("https://youtube.com/watch?v=xyz"), "the snooze of one site doesn't open another")
        #expect(!rule.blocks("https://youtube.com/watch?v=abc"))
    }

    @Test func anAllowListSessionCarriesNoExceptionsIntoItsRule() throws {
        var plan = SessionPlan(goal: "", duration: 3600, mode: .allow, apps: [], websites: ["developer.apple.com"])
        plan.websiteExceptions = [exact("youtube.com/watch?v=abc")]
        let h = Harness()
        h.engine.start(plan)
        let rule = WebsiteRule(enforcement: try #require(h.engine.enforcement), session: h.engine.session)
        #expect(rule.mode == .allow)
        #expect(rule.blocks("https://youtube.com/watch?v=abc"))
    }

    @Test func noSessionMeansNoExceptions() throws {
        let enforcement = Enforcement(mode: .block, apps: [], websites: ["youtube.com"])
        let rule = WebsiteRule(enforcement: enforcement, session: nil)
        #expect(rule.blocks("https://youtube.com/watch?v=abc"))
    }

    @Test func aPlanRoundTripsItsExceptions() throws {
        var plan = SessionPlan(goal: "", duration: 3600, mode: .block, apps: [], websites: ["youtube.com"])
        plan.websiteExceptions = [exact("youtube.com/watch?v=abc"), subtree("youtube.com/@lab")]
        let back = try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(plan))
        #expect(back.websiteExceptions == plan.websiteExceptions)
    }

    @Test func theModelMergesCategoryExceptionsOnce() {
        let a = FocusCategory(id: "a", name: "A", symbol: "circle", apps: [], websites: ["youtube.com"],
                              websiteExceptions: [exact("youtube.com/watch?v=abc")])
        let b = FocusCategory(id: "b", name: "B", symbol: "circle", apps: [], websites: ["youtube.com"],
                              websiteExceptions: [exact("youtube.com/watch?v=abc"), subtree("youtube.com/@lab")])
        let model = NidusModel()
        #expect(model.websiteExceptions(for: [a, b], adding: [subtree("youtube.com/@lab")])
                == [exact("youtube.com/watch?v=abc"), subtree("youtube.com/@lab")])
    }
}

// MARK: - Saved categories

struct ExceptionDecodingTests {
    @Test func aCategorySavedWithExceptionsRoundTrips() throws {
        let category = FocusCategory(id: "video", name: "Video", symbol: "play.rectangle", apps: [],
                                     websites: ["youtube.com"],
                                     websiteExceptions: [exact("youtube.com/watch?v=abc"), subtree("youtube.com/@lab")])
        let data = try JSONEncoder().encode(category)
        #expect(try JSONDecoder().decode(FocusCategory.self, from: data) == category)
    }

    @Test func oneBadExceptionLosesOnlyItself() throws {
        let json = #"{"id":"video","name":"Video","symbol":"play.rectangle","apps":[],"websites":["youtube.com"],"websiteExceptions":[{"kind":"exact","address":"youtube.com/watch?v=a"},{"kind":"sideways","address":"x.com"},{"address":"y.com"},"text",null,{"kind":"subtree","address":"youtube.com/@lab"}]}"#
        let category = try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
        #expect(category.websites == ["youtube.com"])
        #expect(category.websiteExceptions == [exact("youtube.com/watch?v=a"), subtree("youtube.com/@lab")])
    }

    @Test func exceptionsThatAreNotAListDecodeAsNone() throws {
        let json = #"{"id":"video","name":"Video","symbol":"play.rectangle","apps":[],"websites":["youtube.com"],"websiteExceptions":"nope"}"#
        let category = try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
        #expect(category.websites == ["youtube.com"] && category.websiteExceptions.isEmpty)
    }

    @Test func aSavedAddressWithTrackingStillMeansWhatTheNormalizedOneMeans() {
        // Written by hand, or by a later version that stored the address as pasted.
        let raw = exact("https://www.youtube.com/watch?v=abc&utm_source=x&si=Q&t=30s#frag")
        let tidy = exact("youtube.com/watch?v=abc")
        #expect(raw.rule == tidy.rule)
        #expect(raw.rule?.address == "youtube.com/watch?v=abc")
        for url in ["https://youtube.com/watch?v=abc", "https://youtube.com/watch?v=xyz", "https://youtube.com/watch"] {
            #expect(allows(raw, url) == allows(tidy, url), "\(url)")
        }
    }

    @Test func theSummaryCountsExceptionsOnlyWhenThereAreSome() {
        var category = FocusCategory(id: "v", name: "V", symbol: "circle", apps: [], websites: ["youtube.com", "x.com"])
        #expect(category.summary == "2 websites")
        category.websiteExceptions = [exact("youtube.com/watch?v=abc")]
        #expect(category.summary == "2 websites, 1 exception")
        category.websiteExceptions.append(subtree("youtube.com/@lab"))
        #expect(category.summary == "2 websites, 2 exceptions")
    }
}

// MARK: - Making an exception from a pasted address

struct ExceptionDraftTests {
    private func draft(_ address: String, _ kind: WebsiteException.Kind = .exact) throws -> WebsiteExceptionDraft {
        try WebsiteException.draft(from: address, kind: kind).get()
    }

    @Test func trackingAndPositionParametersAreLeftOut() throws {
        let d = try draft("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s&si=AbCd&feature=shared&pp=xyz&ab_channel=Chan&utm_source=news&UTM_Medium=x&fbclid=1&gclid=2")
        #expect(d.exception == exact("youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(d.ignored.map(\.name) == ["t", "si", "feature", "pp", "ab_channel", "utm_source", "UTM_Medium", "fbclid", "gclid"])
        #expect(d.requirement == "v=dQw4w9WgXcQ")
    }

    @Test func theResourceParametersStay() throws {
        #expect(try draft("youtube.com/playlist?list=PL123&si=zz").exception == exact("youtube.com/playlist?list=PL123"))
        #expect(try draft("example.com/doc?id=7&rev=3&utm_campaign=a").exception == exact("example.com/doc?id=7&rev=3"))
    }

    @Test func thePreviewSaysExactlyWhatIsLetThrough() throws {
        let d = try draft("https://youtube.com/watch?v=abc&t=30")
        #expect(d.permits == "Only youtube.com/watch?v=abc")
        #expect(d.summary == "Only youtube.com/watch?v=abc. The rest of youtube.com stays blocked.")
        #expect(d.details.contains("The address must have v=abc. Other parameters are ignored."))
        #expect(d.details.contains("Left out as tracking or position: t."))
        #expect(d.details.contains("Only on youtube.com and www.youtube.com, not other subdomains."))
        #expect(d.warnings.isEmpty)
    }

    @Test func aPreviewWithoutAParameterSaysAnyParameterWorks() throws {
        let d = try draft("example.com/paper")
        #expect(d.summary == "Only example.com/paper, with any ?parameters. The rest of example.com stays blocked.")
        #expect(d.requirement == nil)
        #expect(d.warnings.isEmpty, "nothing was dropped, nothing to second-guess")
    }

    @Test func aQueryOfOnlyTrackingIsSaidToIdentifyNothing() throws {
        let d = try draft("https://youtube.com/watch?utm_source=x&si=1")
        #expect(d.exception == exact("youtube.com/watch"))
        #expect(d.warnings.contains { $0.contains("Nothing after the ? identifies the page") })
    }

    @Test func aSubtreePreviewNamesThePathAndWhatStaysBlocked() throws {
        let d = try draft("https://www.youtube.com/@lab/videos?sort=new", .subtree)
        #expect(d.exception == subtree("youtube.com/@lab/videos"))
        #expect(d.summary == "Everything at youtube.com/@lab/videos and below. The rest of youtube.com stays blocked.")
        #expect(d.warnings.contains { $0.contains("doesn\u{2019}t use sort=new") })
    }

    @Test func aSubtreeOnAWholeHostSaysSubdomainsStayBlocked() throws {
        let d = try draft("youtube.com", .subtree)
        #expect(d.summary == "All of youtube.com. Subdomains like m.youtube.com stay blocked.")
    }

    @Test func aVideoAddressAsASubtreeWarnsThatEveryVideoIsLetThrough() throws {
        let d = try draft("https://youtube.com/watch?v=abc", .subtree)
        #expect(d.exception == subtree("youtube.com/watch"))
        let warning = try #require(d.warnings.first)
        #expect(warning.contains("v=abc") && warning.contains("every page under youtube.com/watch"))
    }

    @Test func aRoutePastTheHashIsSaidToBeInvisible() throws {
        let d = try draft("https://app.example.com/#/projects/42")
        #expect(d.exception == exact("app.example.com"))
        #expect(d.warnings.contains { $0.contains("after the #") })
        #expect(try draft("https://example.com/page#section-2").warnings.isEmpty, "an ordinary anchor is no route")
    }

    @Test func portsAndEncodingShowInTheAddress() throws {
        #expect(try draft("http://Dev.Example.com:8080/Docs/caf%C3%A9?x=1").exception == exact("dev.example.com:8080/Docs/café?x=1"))
        #expect(try draft("example.com/a%2Fb").exception == exact("example.com/a%2Fb"))
        #expect(try draft("example.com/100%").exception == exact("example.com/100%25"))
    }

    @Test func theSameNameWithTwoValuesIsRefused() {
        #expect(WebsiteException.draft(from: "youtube.com/watch?v=a&v=b", kind: .exact) == .failure(.conflictingParameter("v")))
        #expect(WebsiteException.draft(from: "youtube.com/watch?v=a&v=a", kind: .exact).isSuccess, "a repeat of the same pair is one")
    }

    @Test func aNormalizedAddressReadsBackAsItself() throws {
        for address in ["https://www.YouTube.com/watch?v=AbC&t=3", "dev.example.com:8080/docs/a%2Fb?x=a+b&y=c%26d",
                        "example.com/café?q=100%25", "example.com/", "EXAMPLE.com./a//b/../c/"] {
            for kind in WebsiteException.Kind.choices {
                let d = try draft(address, kind)
                let again = try draft(d.exception.address, kind)
                #expect(again.exception == d.exception, "\(address) as \(kind)")
                #expect(d.exception.rule == d.rule)
            }
        }
    }

    @Test func theListSaysTheSameSentenceThePreviewDid() throws {
        for (address, kind) in [("https://youtube.com/watch?v=abc&t=3", WebsiteException.Kind.exact),
                                ("youtube.com/@lab", .subtree), ("youtube.com", .subtree), ("example.com/paper", .exact)] {
            let d = try draft(address, kind)
            #expect(d.exception.rule?.summary == d.summary, "\(address)")
        }
        #expect(exact("youtube.com/watch?v=abc").rule?.summary == "Only youtube.com/watch?v=abc. The rest of youtube.com stays blocked.")
    }

    @Test func errorsComeInPlainWords() {
        #expect(WebsiteExceptionProblem.notAWebAddress.message?.contains("web address") == true)
        #expect(WebsiteExceptionProblem.empty.message == nil)
        #expect(WebsiteException.draft(from: "ftp://example.com/x", kind: .exact) == .failure(.notAWebAddress))
        #expect(WebsiteException.draft(from: "   ", kind: .exact) == .failure(.empty))
    }
}

// MARK: - Whether an exception does anything

struct ExceptionReachTests {
    @Test func anExceptionInsideAListedSiteDoesSomething() {
        #expect(exact("youtube.com/watch?v=abc").isReachable(by: ["youtube.com"]))
        #expect(exact("m.youtube.com/watch?v=abc").isReachable(by: ["youtube.com"]), "the rule covers subdomains")
        #expect(subtree("youtube.com/@lab").isReachable(by: ["youtube.com", "x.com"]))
        #expect(exact("youtube.com/shorts/abc").isReachable(by: ["youtube.com/shorts"]))
    }

    @Test func anExceptionOutsideEveryListedSiteDoesNothing() {
        #expect(!exact("vimeo.com/123").isReachable(by: ["youtube.com"]))
        #expect(!exact("youtube.com/watch?v=abc").isReachable(by: ["youtube.com/shorts"]), "the rule is for /shorts only")
        #expect(!exact("youtube.com/watch?v=abc").isReachable(by: []))
        #expect(!exact("notyoutube.com/watch?v=abc").isReachable(by: ["youtube.com"]))
        #expect(!exact("youtube.com/watch?v=abc").isReachable(by: ["m.youtube.com"]), "an exception on the parent isn't under a subdomain's rule")
        #expect(!exact("garbage").isReachable(by: ["youtube.com"]))
    }

    @Test func aSubtreeAboveARulesPathStillReachesIt() {
        #expect(subtree("youtube.com").isReachable(by: ["youtube.com/shorts"]))
        #expect(!subtree("youtube.com/watch").isReachable(by: ["youtube.com/shorts"]))
        #expect(!exact("youtube.com").isReachable(by: ["youtube.com/shorts"]), "the front page isn't a short")
    }

    @Test func theReachCheckIgnoresCaseLikeTheRulesDo() {
        #expect(exact("example.com/Papers/Aims").isReachable(by: ["example.com/papers"]))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
