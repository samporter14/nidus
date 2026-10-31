//
//  ProtectionStatusTests.swift
//  NidusTests
//
//  The protection line says what a session covers, gaps first; browsers
//  Nidus can't watch are found and offered once; blocking them as apps lasts
//  for the session only.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct ProtectionStatusTests {
    @Test func allCoveredSaysWhere() {
        let status = ProtectionStatus(watched: ["Safari", "Chrome"])
        #expect(status.isComplete)
        #expect(status.line == "Sites blocked in Safari and Chrome")
    }

    @Test func gapsComeFirst() {
        let status = ProtectionStatus(watched: ["Safari"], noPermission: ["Chrome"], unwatched: ["Firefox"],
                                      refused: ["Slack"])
        #expect(!status.isComplete)
        #expect(status.line == "No permission for Chrome \u{00B7} Sites not blocked in Firefox \u{00B7} Slack wouldn\u{2019}t quit")
    }

    @Test func appsOnlySessionsDoNotTalkAboutBrowsers() {
        let status = ProtectionStatus(noPermission: ["Chrome"], unwatched: ["Firefox"], blocksWebsites: false)
        #expect(status.isComplete == false, "a gap is still a gap in the data")
        #expect(status.line == "Blocking apps")
        #expect(ProtectionStatus(blocksWebsites: false).line == "Blocking apps")
        #expect(ProtectionStatus().line == "Sites blocked in any browser you open")
    }

    @Test func listsReadAsEnglish() {
        #expect(ProtectionStatus.list(["A"]) == "A")
        #expect(ProtectionStatus.list(["A", "B", "C"]) == "A, B and C")
    }

    @Test func knownBrowsersAndNidusAreNotUncovered() {
        let found = UncoveredBrowsers.uncovered(["com.apple.Safari", "org.mozilla.firefox", "com.google.Chrome",
                                                 "local.sam.nidus", "app.zen-browser.zen", "org.mozilla.firefox",
                                                 "com.apple.finder"],
                                                ownBundleID: "local.sam.nidus")
        #expect(found == ["org.mozilla.firefox", "app.zen-browser.zen"])
    }

    @Test func browsersAlreadyBlockedAsAppsAreNotOffered() {
        let mode = AppBlocker.Mode.block(["org.mozilla.firefox"])
        let offer = UncoveredBrowsers.toOffer(["org.mozilla.firefox", "com.microsoft.edgemac"],
                                              blockedAsApp: { AppBlocker.isBlocked($0, under: mode) })
        #expect(offer == ["com.microsoft.edgemac"])
        // An allow list blocks every browser it doesn't name: nothing to offer.
        let allow = AppBlocker.Mode.allow(["com.apple.dt.Xcode"])
        #expect(UncoveredBrowsers.toOffer(["org.mozilla.firefox"], blockedAsApp: { AppBlocker.isBlocked($0, under: allow) }).isEmpty)
    }

    @Test func firefoxAndZenAreNamed() {
        #expect(UncoveredBrowsers.named["org.mozilla.firefox"] == "Firefox")
        #expect(UncoveredBrowsers.named["app.zen-browser.zen"] == "Zen")
        // Never a browser Nidus does script.
        for browser in BrowserProfile.known { #expect(UncoveredBrowsers.named[browser.bundleID] == nil) }
    }

    @Test func blockingAsAppsLastsForTheSessionOnly() {
        let engine = SessionEngine(store: nil)
        engine.start(SessionPlan(goal: "Write", duration: 600, mode: .block, apps: ["com.tinyspeck.slackmacgap"],
                                 websites: ["youtube.com"]))
        engine.blockAppsForSession(["org.mozilla.firefox", "com.tinyspeck.slackmacgap"])
        #expect(engine.session?.plan.apps == ["com.tinyspeck.slackmacgap", "org.mozilla.firefox"])
        #expect(engine.enforcement?.apps.contains("org.mozilla.firefox") == true)

        let allow = SessionEngine(store: nil)
        allow.start(SessionPlan(goal: "Write", duration: 600, mode: .allow, apps: ["org.mozilla.firefox", "com.apple.dt.Xcode"],
                                websites: []))
        allow.blockAppsForSession(["org.mozilla.firefox"])
        #expect(allow.session?.plan.apps == ["com.apple.dt.Xcode"])
    }
}
