//
//  BreakRulesTests.swift
//  NidusTests
//
//  0.4, breaks with their own rules: the break's length and rules come from
//  the plan, a break with rules blocks only them, the work session's rules
//  are released without exposing a page both block, and ending, skipping or
//  quitting cleans up as a session end does. Nothing here touches a browser,
//  an app or the real folder: the controller tests run unrestricted, and the
//  tab decisions are the pure functions the controller calls.
//

import Foundation
import Testing
@testable import Nidus

private let socialAndX = BreakRules(apps: ["com.tinyspeck.slackmacgap"], websites: ["x.com", "reddit.com"], reminder: "Stretch, water")

@MainActor
struct BreakLengthTests {
    private func finish(_ plan: SessionPlan, settingsBreak: Double) -> Harness {
        let h = Harness()
        h.engine.breakLength = settingsBreak * minute
        h.engine.start(plan)
        h.clock.advance(plan.duration ?? 0)
        h.engine.tick()
        return h
    }

    @Test func aPlanWithoutALengthKeepsSettingsBreakExactly() {
        let h = finish(plan(25), settingsBreak: 5)
        #expect(h.engine.breakState?.length == 5 * minute)
        #expect(h.engine.breakState?.rules == nil, "0.3's break carries no rules")
        #expect(h.engine.enforcement == nil)
        #expect(h.engine.breakRemaining == 5 * minute)
    }

    @Test func aPlansOwnLengthBeatsSettings() {
        var p = plan(25)
        p.breakLength = 12 * minute
        let h = finish(p, settingsBreak: 5)
        #expect(h.engine.breakState?.length == 12 * minute)
        #expect(h.engine.breakRemaining == 12 * minute)
    }

    @Test func aPlanCanTakeABreakSettingsDoesNot() {
        var p = plan(25)
        p.breakLength = 8 * minute
        let h = finish(p, settingsBreak: 0)
        #expect(h.engine.breakState?.length == 8 * minute)
    }

    @Test func aPlanCanTakeNoBreakWhereSettingsHasOne() {
        var p = plan(25)
        p.breakLength = 0
        let h = finish(p, settingsBreak: 5)
        #expect(!h.engine.isOnBreak, "an explicit none is not Settings' value")
    }

    @Test func theBreakCarriesThePlansRules() {
        var p = plan(25)
        p.breakRules = socialAndX
        let h = finish(p, settingsBreak: 5)
        #expect(h.engine.breakState?.rules == socialAndX)
    }

    @Test func aLegacyPlanBehavesAsItDid() throws {
        // A plan saved by 0.3 has none of the new fields.
        let old = #"{"goal":"Chapter three","duration":1500,"mode":"block","apps":[],"websites":["youtube.com"]}"#
        let p = try JSONDecoder().decode(SessionPlan.self, from: Data(old.utf8))
        let h = finish(p, settingsBreak: 5)
        #expect(h.engine.breakState?.length == 5 * minute)
        #expect(h.engine.breakState?.rules == nil)
        #expect(h.engine.enforcement == nil)
        h.clock.advance(5 * minute)
        h.engine.tick()
        #expect(h.engine.session?.plan.goal == "Chapter three")
        #expect(h.engine.remaining == 25 * minute)
    }

    @Test func endedEarlyOrOpenEndedStillEarnsNoBreak() {
        var p = plan(25)
        p.breakLength = 10 * minute
        p.breakRules = socialAndX
        let h = Harness()
        h.engine.start(p)
        h.engine.end()
        #expect(!h.engine.isOnBreak)
        var open = p
        open.duration = nil
        h.engine.start(open)
        h.clock.advance(SessionPlan.maximumDuration)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
    }
}

@MainActor
struct BreakEnforcementTests {
    private func onBreak(rules: BreakRules?) -> Harness {
        var p = plan(25)
        p.breakLength = 5 * minute
        p.breakRules = rules
        let h = Harness()
        h.engine.start(p)
        h.clock.advance(25 * minute)
        h.engine.tick()
        return h
    }

    @Test func aBreakWithRulesBlocksOnlyThemInBlockMode() {
        let h = onBreak(rules: socialAndX)
        #expect(h.engine.isOnBreak && h.engine.session == nil)
        #expect(h.engine.enforcement == Enforcement(mode: .block, apps: ["com.tinyspeck.slackmacgap"],
                                                    websites: ["x.com", "reddit.com"]))
    }

    @Test func theWorkSessionsRulesAreReleased() {
        // The session blocked youtube.com and Slack's own list; the break does not.
        let h = onBreak(rules: BreakRules(websites: ["x.com"]))
        #expect(h.engine.enforcement?.websites == ["x.com"])
        #expect(h.engine.enforcement?.apps.isEmpty == true)
    }

    @Test func anAllowListSessionsBreakIsStillABlockList() {
        var p = plan(25, mode: .allow)
        p.breakLength = 5 * minute
        p.breakRules = BreakRules(websites: ["x.com"])
        let h = Harness()
        h.engine.start(p)
        #expect(h.engine.enforcement?.mode == .allow)
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(h.engine.enforcement?.mode == .block, "a break never narrows to an allow list")
    }

    @Test func anUnrestrictedBreakBlocksNothingAsBefore() {
        #expect(onBreak(rules: nil).engine.enforcement == nil)
        #expect(onBreak(rules: BreakRules()).engine.enforcement == nil)
        let reminderOnly = onBreak(rules: BreakRules(reminder: "Water"))
        #expect(reminderOnly.engine.enforcement == nil, "a note alone blocks nothing")
        #expect(reminderOnly.engine.breakState?.rules?.displayReminder == "Water")
    }

    @Test func skippingTheBreakHandsBlockingBackToTheSession() {
        let h = onBreak(rules: socialAndX)
        h.engine.skipBreak()
        #expect(h.engine.enforcement?.websites == ["youtube.com"], "the session's rule, not the break's")
        #expect(h.engine.enforcement?.apps == ["com.tinyspeck.slackmacgap"])
    }

    @Test func endingTheBreakReleasesEverythingLikeASessionEnd() {
        let h = onBreak(rules: socialAndX)
        h.engine.endBreak()
        #expect(h.engine.enforcement == nil)
        #expect(!h.engine.isOnBreak)
        #expect(h.events.last == .breakEnded)
    }

    @Test func theBreakEndingOnItsOwnStartsTheSessionBack() {
        let h = onBreak(rules: socialAndX)
        h.clock.advance(5 * minute)
        h.engine.tick()
        #expect(h.engine.session != nil)
        #expect(h.engine.enforcement?.websites == ["youtube.com"])
        #expect(h.engine.session?.plan.breakRules == socialAndX, "the next break carries them too")
    }

    @Test func aRestrictedBreakSurvivesARelaunchWithItsRules() {
        let h = onBreak(rules: socialAndX)
        h.clock.advance(minute)
        let (engine, _) = h.relaunch()
        #expect(engine.isOnBreak)
        #expect(engine.breakState?.rules == socialAndX)
        #expect(engine.enforcement?.websites == ["x.com", "reddit.com"])
        #expect(engine.breakRemaining == 4 * minute)
    }

    @Test func breakTimeIsNeverFocusTime() {
        let h = onBreak(rules: socialAndX)
        #expect(h.engine.elapsed == nil && h.engine.remaining == nil)
        // The one session ended before the break began; the break adds no entry.
        let ended = h.events.all.compactMap { event -> SessionState? in
            if case .ended(_, let state) = event { state } else { nil }
        }
        #expect(ended.count == 1)
        h.engine.recordBlock("x.com", name: "x.com")
        #expect(h.engine.session == nil, "a block during a break is counted nowhere")
    }

    @Test func aStillRunningRestrictedBreakResumesAsAContinuation() {
        let h = onBreak(rules: socialAndX)
        #expect(h.engine.breakState?.plan.isContinuation == false)
        h.engine.skipBreak()
        #expect(h.engine.session?.plan.isContinuation == true,
                "documents and pages are not opened a second time; apps and the Shortcut run again")
    }

    @Test func aPlanStartedByHandIsNotAContinuation() {
        var p = plan(25)
        p.isContinuation = true
        p.sequenceStep = SequenceStepRef(runID: UUID(), index: 1, count: 3)
        let h = Harness()
        h.engine.start(p)
        #expect(h.engine.session?.plan.isContinuation == false)
        #expect(h.engine.session?.plan.sequenceStep == nil)
        #expect(h.engine.sequence == nil)
    }
}

// MARK: - Tabs between rules

struct BreakTabHandlingTests {
    private let session = Enforcement(mode: .block, apps: [], websites: ["youtube.com", "reddit.com", "x.com"])
    private let restricted = Enforcement(mode: .block, apps: [], websites: ["x.com", "reddit.com"])

    @MainActor
    @Test func sessionToRestrictedBreakKeepsTheRuleNotLiftsIt() {
        #expect(FocusController.tabHandling(from: session, to: restricted) == .keepBlocked(by: restricted))
    }

    @MainActor
    @Test func theEndsOfBlockingAreRestoreAllAndNothing() {
        #expect(FocusController.tabHandling(from: restricted, to: nil) == .restoreAll)
        #expect(FocusController.tabHandling(from: nil, to: restricted) == .leave)
        #expect(FocusController.tabHandling(from: nil, to: nil) == .leave)
    }

    private func blockedTab(_ original: String, index: Int, page: BlockPage) -> TabLocation {
        TabLocation(windowID: 1, index: index, url: page.url(blocking: original, goal: "Aims", snoozeMinutes: 3, snoozeKey: ""))
    }

    /// The tabs the browser would be handed back, with no Apple Events: only
    /// the choice of tabs.
    @MainActor
    private func restored(_ tabs: [TabLocation], keeping rule: WebsiteRule?, page: BlockPage) -> [String] {
        BrowserBlocker(blockPage: page).restorations(in: tabs, keepBlocked: rule).map(\.original)
    }

    @MainActor
    @Test func aPageBlockedByBothStaysBlockedAndOnlyTheSessionsIsPutBack() {
        let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/nidus-test-block"))
        let tabs = [blockedTab("https://youtube.com/watch?v=a", index: 1, page: page),
                    blockedTab("https://x.com/home", index: 2, page: page),
                    blockedTab("https://www.reddit.com/r/all", index: 3, page: page)]
        let rule = FocusController.websiteRule(for: restricted)
        #expect(restored(tabs, keeping: rule, page: page) == ["https://youtube.com/watch?v=a"],
                "x.com and reddit.com are blocked by the session and the break, so never put back in between")
    }

    @MainActor
    @Test func aBlockedTabIsNotRestoredUntilTheBreakRestrictionEnds() {
        let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/nidus-test-block"))
        let tabs = [blockedTab("https://x.com/home", index: 1, page: page)]
        let during = FocusController.websiteRule(for: restricted)
        #expect(restored(tabs, keeping: during, page: page).isEmpty)
        // The break ends: no rule keeps anything.
        #expect(restored(tabs, keeping: nil, page: page) == ["https://x.com/home"])
    }

    @MainActor
    @Test func breakToSessionPutsBackOnlyWhatTheSessionDoesNotBlock() {
        let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/nidus-test-block"))
        let tabs = [blockedTab("https://x.com/home", index: 1, page: page),
                    blockedTab("https://news.ycombinator.com", index: 2, page: page)]
        let onlyYoutubeAndX = Enforcement(mode: .block, apps: [], websites: ["youtube.com", "x.com"])
        let handling = FocusController.tabHandling(from: Enforcement(mode: .block, apps: [], websites: ["x.com", "news.ycombinator.com"]),
                                                   to: onlyYoutubeAndX)
        guard case .keepBlocked(let next) = handling else { Issue.record("expected keepBlocked"); return }
        #expect(restored(tabs, keeping: FocusController.websiteRule(for: next), page: page) == ["https://news.ycombinator.com"])
    }

    @MainActor
    @Test func quitAppsAreNotReopenedIntoABreakThatBlocksThemAgain() {
        let reopened = FocusController.appsToReopen(["com.tinyspeck.slackmacgap", "com.apple.mail"],
                                                    under: Enforcement(mode: .block, apps: ["com.tinyspeck.slackmacgap"], websites: []))
        #expect(reopened == ["com.apple.mail"])
        #expect(FocusController.appsToReopen(["a", "b"], under: nil) == ["a", "b"], "nothing follows: as before")
        let allow = Enforcement(mode: .allow, apps: ["a"], websites: [])
        #expect(FocusController.appsToReopen(["a", "b"], under: allow) == ["a"])
    }

    @MainActor
    @Test func quittingMarksTabsRestoredForABreakToo() {
        #expect(FocusController.marksTabsRestored(restored: 2, hasSession: true, isOnBreak: false))
        #expect(FocusController.marksTabsRestored(restored: 2, hasSession: false, isOnBreak: true))
        #expect(!FocusController.marksTabsRestored(restored: 0, hasSession: true, isOnBreak: false))
        #expect(!FocusController.marksTabsRestored(restored: 2, hasSession: false, isOnBreak: false))
    }
}

@MainActor
struct BreakQuitTests {
    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-break-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aBreakThatResumesQuietsTheFirstSweepAfterAQuit() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A break holding only a reminder, so nothing is blocked while this runs.
        let next = SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: [])
        FileSessionStore(url: dir.appendingPathComponent("session.json")).save(SessionRecord(
            lastPlan: next,
            pendingBreak: BreakState(plan: next, endsAt: Date().addingTimeInterval(300), length: 300,
                                     rules: BreakRules(reminder: "Water"))))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("tabs-restored").path, contents: Data())
        let controller = FocusController(directory: dir)
        controller.start()
        defer { controller.stop() }
        #expect(controller.engine.isOnBreak)
        #expect(controller.quietsNextSweep)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tabs-restored").path))
    }

    @Test func aDemoBreakWithRulesBlocksNothingOnTheMac() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.blocksNothing = true
        controller.start()
        defer { controller.stop() }
        var next = SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: [])
        next.breakRules = socialAndX
        controller.engine.startBreak(plan: next, length: 300)
        // The engine carries the rules; the controller, told to block nothing,
        // never acts on them (it has no browser or app to touch to prove it,
        // which is the point).
        #expect(controller.engine.enforcement?.websites == ["x.com", "reddit.com"])
        #expect(controller.blocksNothing)
    }
}

// MARK: - Choosing the rules

struct BreakRulesEditingTests {
    private let social = FocusCategory(id: "social", name: "Social", symbol: "person.2", apps: [],
                                       websites: ["x.com", "reddit.com"])
    private let messaging = FocusCategory(id: "messaging", name: "Messaging", symbol: "bubble.left",
                                          apps: [BlockedApp(bundleID: "com.slack", name: "Slack")],
                                          websites: ["reddit.com", "discord.com"])
    private let empty = FocusCategory(id: "empty", name: "Empty", symbol: "square", apps: [], websites: [])

    private var categories: [FocusCategory] { [social, messaging, empty] }

    @Test func aCategoryIsOnWhenEverythingInItIsBlocked() {
        let rules = BreakRules(websites: ["x.com", "reddit.com"])
        #expect(rules.covers(social))
        #expect(!rules.covers(messaging), "partly covered is not on")
        #expect(!rules.covers(empty), "an empty category is never on")
    }

    @Test func turningACategoryOnAddsItsAppsAndSitesOnce() {
        let rules = BreakRules().setting(social, on: true, in: categories).setting(messaging, on: true, in: categories)
        #expect(rules.websites == ["x.com", "reddit.com", "discord.com"])
        #expect(rules.apps == ["com.slack"])
    }

    @Test func turningOneOffKeepsWhatAnotherOneOnStillHolds() {
        let both = BreakRules().setting(social, on: true, in: categories).setting(messaging, on: true, in: categories)
        let withoutSocial = both.setting(social, on: false, in: categories)
        #expect(withoutSocial.websites.contains("reddit.com"), "Messaging, still on, holds reddit.com too")
        #expect(!withoutSocial.websites.contains("x.com"))
        #expect(withoutSocial.covers(messaging))
        let none = withoutSocial.setting(messaging, on: false, in: categories)
        #expect(none.isUnrestricted)
    }

    @Test func otherAppsAndSitesAreWhatNoCategoryAccountsFor() {
        var rules = BreakRules().setting(social, on: true, in: categories)
        rules = rules.adding(apps: ["com.example.Game", "com.example.Game"]).adding(website: "https://www.Example.com/path/?q=1")
        let extras = rules.extras(in: categories)
        #expect(extras.apps == ["com.example.Game"])
        #expect(extras.websites == ["example.com/path"], "typed as a category's websites are")
        #expect(rules.adding(website: "not a site at all ").websites == rules.websites)
        #expect(rules.removing(app: "com.example.Game").apps.isEmpty)
        #expect(rules.removing(website: "example.com/path").websites == ["x.com", "reddit.com"])
    }

    @Test func theReminderIsBoundedAndBlankIsNone() {
        #expect(BreakRules().settingReminder("   ").reminder == nil)
        let long = String(repeating: "a", count: 300)
        #expect(BreakRules().settingReminder(long).reminder?.count == BreakRules.reminderLimit)
        #expect(BreakRules().settingReminder("Stretch, water").displayReminder == "Stretch, water")
    }

    @Test func theLineSaysWhatStaysBlockedAndUntilWhen() {
        let rules = BreakRules(apps: ["com.slack"], websites: ["x.com", "reddit.com"])
        let name: (String) -> String = { $0 == "com.slack" ? "Slack" : $0 }
        #expect(rules.setting(social, on: true, in: categories).stayBlockedLine(categories: categories, appName: name, until: "10:40")
                == "Social and Slack stay blocked until 10:40")
        #expect(BreakRules(websites: ["x.com"]).stayBlockedLine(categories: [], appName: name, until: "10:40")
                == "x.com stays blocked until 10:40")
        #expect(BreakRules(reminder: "Water").stayBlockedLine(categories: categories, appName: name, until: "10:40") == nil)
        #expect(BreakRules(websites: ["a.com", "b.com", "c.com", "d.com", "e.com"])
            .stayBlockedLine(categories: [], appName: name, until: "9:00") == "a.com, b.com, c.com and 2 more stay blocked until 9:00")
    }

    @Test func rulesRoundTripWithTheirReminder() throws {
        let rules = BreakRules(apps: ["a"], websites: ["x.com"], reminder: "Water")
        let decoded = try JSONDecoder().decode(BreakRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
    }
}
