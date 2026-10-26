import AppKit
import Testing
@testable import Nidus

@MainActor
struct ExternalWorkspaceBoundaryTests {
    @Test func linksAndAutomationCannotOpenASavedWorkspaceOrRunItsShortcuts() throws {
        let target = FakeFocusTarget()
        let resource = WorkspaceResource(kind: .webPage, displayName: "Example", url: "https://example.com")
        let setup = FocusSetup(name: "Work", categoryIDs: ["social"], strict: true,
                               startShortcut: "Dangerous shortcut", endShortcut: "End action", resources: [resource])
        target.setups = [setup]
        let request = try target.outsideRequest(NidusLink.Start(preset: setup.id.uuidString), fromLink: true).get().request
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: target.categories,
                                     startShortcut: "Settings on", endShortcut: "Settings off")
        let plan = try #require(request.resolved(with: defaults, length: { (25, false) })?.plan)
        #expect(plan.resources.isEmpty)
        #expect(plan.startShortcut == nil && plan.endShortcut == nil, "empty overrides cannot inherit Settings")
        #expect(plan.strict && plan.setupID == setup.id)
        #expect(setup.resources == [resource], "the setup itself is untouched")
    }

    @Test func aPlainLinkStartDoesNotInheritShortcutSideEffects() throws {
        let request = try FakeFocusTarget().outsideRequest(NidusLink.Start(), fromLink: true).get().request
        #expect(request.resources.isEmpty && request.startShortcut == "" && request.endShortcut == "")
    }

    @Test func aShortcutOrJSONStartKeepsTheSetupsWorkspaceAndShortcuts() throws {
        // Only a link can come from a web page. A Shortcuts action or the JSON
        // command is the person's own, and is how an Apple Focus gets switched on.
        let target = FakeFocusTarget()
        let resource = WorkspaceResource(kind: .webPage, displayName: "Example", url: "https://example.com")
        let setup = FocusSetup(name: "Work", categoryIDs: ["social"], startShortcut: "Focus on", endShortcut: "Focus off",
                               resources: [resource])
        target.setups = [setup]
        let request = try target.outsideRequest(NidusLink.Start(preset: setup.id.uuidString)).get().request
        #expect(request.resources == [resource])
        #expect(request.startShortcut == "Focus on" && request.endShortcut == "Focus off")
        let plain = try target.outsideRequest(NidusLink.Start()).get().request
        #expect(plain.startShortcut == nil && plain.endShortcut == nil, "no setup: Settings' Shortcuts apply, as before")
    }
}

@MainActor
struct FrozenBreakTests {
    @Test func editingSettingsDuringWorkDoesNotChangeItsBreak() throws {
        let category = FocusCategory(id: "test", name: "Test", symbol: "circle", apps: [], websites: ["example.com"])
        var defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["test"], categories: [category],
                                     defaultBreakLength: 5 * 60)
        let request = SessionRequest(goal: "", minutes: 1)
        let plan = try #require(request.resolved(with: defaults, length: { (1, false) })?.plan)
        let h = Harness()
        h.engine.start(plan)
        defaults.defaultBreakLength = 20 * 60
        h.engine.breakLength = defaults.defaultBreakLength
        h.clock.advance(61)
        h.engine.tick()
        #expect(h.engine.isOnBreak)
        let rest = try #require(h.engine.breakState)
        #expect(rest.length == 300)
        #expect(rest.plan.breakLength == 300)
    }

    @Test func noBreakCannotBecomeABreakThroughSettings() throws {
        let category = FocusCategory(id: "test", name: "Test", symbol: "circle", apps: [], websites: ["example.com"])
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["test"], categories: [category])
        let plan = try #require(SessionRequest(goal: "", minutes: 1).resolved(with: defaults, length: { (1, false) })?.plan)
        let h = Harness()
        h.engine.start(plan)
        h.engine.breakLength = 600
        h.clock.advance(61)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
    }
}

struct BlockPageTransitionTests {
    private let page = BlockPage(directory: URL(fileURLWithPath: "/tmp/nidus-test-page"))

    @Test func breakRefreshRemovesTheOldGoalAndSnoozeWithoutRestoringTheSite() throws {
        let blocker = BrowserBlocker(blockPage: page)
        let old = TabLocation(windowID: 1, index: 1,
                              url: page.url(blocking: "https://x.com/a", goal: "Work", snoozeMinutes: 3, snoozeKey: "x.com"))
        let rule = WebsiteRule(mode: .block, domains: ["x.com"])
        #expect(blocker.restorations(in: [old], keepBlocked: rule).isEmpty)
        let refreshed = try #require(blocker.refreshes(in: [old], rule: rule, context: .init(onBreak: true)).first)
        let items = URLComponents(string: refreshed.page)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "b", value: "1")))
        #expect(items.contains(URLQueryItem(name: "m", value: "0")))
        #expect(items.contains(URLQueryItem(name: "g", value: "")))
        #expect(page.original(from: refreshed.page) == "https://x.com/a")
        let current = TabLocation(windowID: 1, index: 1, url: refreshed.page)
        #expect(blocker.refreshes(in: [current], rule: rule, context: .init(onBreak: true)).isEmpty,
                "unchanged pages never reload")
    }

    @Test func identicalBlockListsStillRestoreTheNextBlocksNewException() throws {
        let blocker = BrowserBlocker(blockPage: page)
        let original = "https://youtube.com/watch?v=study"
        let tab = TabLocation(windowID: 1, index: 1, url: page.url(blocking: original))
        let exception = WebsiteException(kind: .exact, address: original)
        let rule = WebsiteRule(mode: .block, domains: ["youtube.com"], exceptions: [exception])
        #expect(blocker.restorations(in: [tab], keepBlocked: rule).first?.original == original)
        #expect(blocker.refreshes(in: [tab], rule: rule, context: .init()).isEmpty)
        let enforcement = Enforcement(mode: .block, apps: [], websites: ["youtube.com"])
        #expect(FocusController.restartsBlocker(sessionStarted: true, from: enforcement, to: enforcement))
    }
}

struct PresetExpansionTests {
    @Test func versionTwoOnlyExtendsExistingPresetsOnce() throws {
        let saved = [FocusCategory(id: "social", name: "My social", symbol: "leaf", apps: [], websites: ["x.com", "my.example"])]
        let updated = PresetUpdates.applying(to: saved, since: 1)
        let social = try #require(updated.first)
        #expect(social.name == "My social" && social.symbol == "leaf")
        #expect(social.websites.prefix(2) == ["x.com", "my.example"])
        #expect(social.websites.contains("t.co") && social.websites.contains("substack.com/notes"))
        #expect(updated.count == 1, "whole new categories are not inserted")
        #expect(PresetUpdates.applying(to: saved, since: 2) == saved, "removed sites stay removed")
        #expect(PresetUpdates.applying(to: [], since: 0).isEmpty, "deleted presets stay deleted")
    }

    @Test func everyFreshPresetIsNormalizedAndEveryAdditionIsPresent() {
        for category in FocusCategory.presets {
            #expect(Set(category.websites).count == category.websites.count)
            for site in category.websites { #expect(FocusCategory.domain(from: site) == site) }
        }
        #expect(FocusCategory.defaultSelection == ["social", "video"])
        #expect(!FocusCategory.defaultSelection.contains("ai-chat"))
        #expect(!FocusCategory.presets.flatMap(\.websites).contains("stackoverflow.com"))
        for addition in PresetUpdates.additions {
            let category = FocusCategory.presets.first { $0.id == addition.id }
            #expect(Set(addition.sites).isSubset(of: Set(category?.websites ?? [])))
        }
    }

    @Test func mailAndNotesDefaultsLeaveUnrelatedWorkPagesAlone() throws {
        let mail = try #require(FocusCategory.presets.first { $0.id == "mail" })
        let social = try #require(FocusCategory.presets.first { $0.id == "social" })
        let mailRule = WebsiteRule(mode: .block, domains: mail.websites)
        let socialRule = WebsiteRule(mode: .block, domains: social.websites)
        #expect(mailRule.blocks("https://icloud.com/mail/inbox"))
        #expect(!mailRule.blocks("https://icloud.com/iclouddrive"))
        #expect(socialRule.blocks("https://substack.com/notes"))
        #expect(!socialRule.blocks("https://substack.com/home"))
    }

    @Test func aDuplicateOnlyMergesWhenEveryRuleIsPreserved() throws {
        let news = try #require(FocusCategory.presets.first { $0.id == "news" })
        var custom = FocusCategory(id: "custom-news", name: "News", symbol: "circle", apps: [], websites: ["bbc.com", "cnn.com"])
        #expect(custom.mergeTarget(in: [custom, news])?.id == "news")
        custom.websites.append("personal-blog.example")
        #expect(custom.mergeTarget(in: [custom, news]) == nil)
        custom.websites = ["bbc.com"]
        custom.websiteExceptions = [WebsiteException(kind: .exact, address: "https://bbc.com/study")]
        #expect(custom.mergeTarget(in: [custom, news]) == nil, "an exception cannot be lost")
    }
}

@MainActor
struct NativePolishTests {
    @Test func curatedSymbolsAreUniqueAndExistOnTheTargetSystem() {
        #expect(NidusSymbolCatalog.choices.count == 120)
        #expect(Set(NidusSymbolCatalog.choices.map(\.symbol)).count == 120)
        for choice in NidusSymbolCatalog.choices {
            #expect(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) != nil, "\(choice.symbol)")
        }
        #expect(NidusSymbolCatalog.results(query: "LAB").map(\.symbol).contains("testtube.2"))
        #expect(NidusSymbolCatalog.results(query: "", group: "Health").count == 15)
        #expect(NidusSymbolCatalog.results(query: "qwertyzyx").isEmpty)
    }

    @Test func repeatedJumpsKeepTheExactSettingAndRequestAScrollAgain() throws {
        let jump = SettingsJump { _, _ in }
        let plaque = try #require(SettingsJumpIndex.entries.first { $0.id == "plaque" })
        jump.open(plaque)
        let first = try #require(jump.destination)
        #expect(first.page == "general" && first.anchor == "plaque")
        jump.open(plaque)
        #expect(jump.destination?.request != first.request)
    }

    @Test func archivedPopoverProjectsDoNotLeakIntoSequenceBlocks() {
        let archived = FocusProject(name: "Old project", isArchived: true)
        let setup = FocusSetup(name: "Work", categoryIDs: ["social"])
        let step = FocusSequence.Step.work(setupID: setup.id)
        let sequence = FocusSequence(name: "Workday", steps: [step])
        let request = sequence.request(for: step, setups: [setup], categories: FocusCategory.presets,
                                       popoverProject: archived.id, projects: [archived], projectExists: { _ in true })
        #expect(request.projectID == nil)
    }

    @Test func aRefusedKeyboardStartGivesInlineFeedback() {
        let model = NidusModel()
        model.startSession()
        #expect(model.startProblem != nil)
    }
}
