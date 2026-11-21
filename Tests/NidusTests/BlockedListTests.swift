import Foundation
import Testing
@testable import Nidus

@MainActor
struct BlockedListTests {
    private let social = FocusCategory(id: "social", name: "Social", symbol: "person.2",
                                       apps: [BlockedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
                                              BlockedApp(bundleID: "com.apple.finder", name: "Finder")],
                                       websites: ["x.com"])
    private let mail = FocusCategory(id: "mail", name: "Mail", symbol: "envelope",
                                     apps: [BlockedApp(bundleID: "com.apple.mail", name: "Mail"),
                                            BlockedApp(bundleID: "com.apple.MobileSMS", name: "Messages")],
                                     websites: ["gmail.com", "x.com"])
    private var all: [FocusCategory] { [social, mail] }

    private func plan(_ chosen: [FocusCategory], mode: SessionPlan.Mode = .block, launch: [String] = []) -> SessionPlan {
        SessionPlan(goal: "", duration: 1500, mode: mode, categories: chosen, reopensQuitApps: false, launchApps: launch)
    }

    @Test func groupsByCategoryAndShowsEachItemOnce() {
        let sections = BlockedList.sections(plan: plan(all), categories: all, ownBundleID: nil)
        #expect(sections.map(\.title) == ["Social", "Mail"])
        #expect(sections[0].apps.map(\.name) == ["Messages", "Finder"])
        #expect(sections[0].websites == ["x.com"])
        #expect(sections[1].apps.map(\.name) == ["Mail"])
        #expect(sections[1].websites == ["gmail.com"])
    }

    @Test func itemsNoCategoryNamesGoUnderOther() {
        var p = plan([social])
        p.apps.append("org.example.Stray")
        let sections = BlockedList.sections(plan: p, categories: [social], ownBundleID: nil)
        #expect(sections.last?.title == BlockedList.otherTitle)
        #expect(sections.last?.apps.map(\.bundleID) == ["org.example.Stray"])
    }

    @Test func exemptOwnAndLaunchedAppsAreMarkedNeverBlocked() {
        let own = FocusCategory(id: "x", name: "X", symbol: "x",
                                apps: [BlockedApp(bundleID: "local.sam.nidus", name: "Nidus"),
                                       BlockedApp(bundleID: "org.example.Editor", name: "Editor")], websites: [])
        let sections = BlockedList.sections(plan: plan([social, own], launch: ["org.example.Editor"]),
                                            categories: [social, own], ownBundleID: "local.sam.nidus")
        let marked = Dictionary(uniqueKeysWithValues: sections.flatMap(\.apps).map { ($0.name, $0.neverBlocked) })
        #expect(marked == ["Messages": false, "Finder": true, "Nidus": true, "Editor": true])
    }

    @Test func allowModeDoesNotClaimNeverBlocked() {
        let sections = BlockedList.sections(plan: plan([social], mode: .allow), categories: [social], ownBundleID: nil)
        #expect(sections.flatMap(\.apps).allSatisfy { !$0.neverBlocked })
    }

    @Test func differenceLineSaysAddsAndRemoves() {
        let setup = FocusSetup(minutes: 25, categoryIDs: ["social"], mode: .block, strict: false)
        let saved = BlockedList.Items(setup: setup, categories: all)
        let current = BlockedList.Items(plan: plan([mail]), categories: [mail])
        #expect(BlockedList.differenceLine(setupName: "New setup", current: current, saved: saved)
                == "Differs from setup 'New setup': adds Mail, gmail.com; removes Finder")
        let more = BlockedList.Items(plan: plan(all), categories: all)
        #expect(BlockedList.differenceLine(setupName: "S", current: more, saved: saved)
                == "Differs from setup 'S': adds Mail, gmail.com")
    }

    @Test func noDifferenceMeansNoLineAndModeChangesAreSaid() {
        let setup = FocusSetup(minutes: 25, categoryIDs: ["social"], mode: .block, strict: false)
        let saved = BlockedList.Items(setup: setup, categories: all)
        let same = BlockedList.Items(plan: plan([social]), categories: [social])
        #expect(BlockedList.differenceLine(setupName: "S", current: same, saved: saved) == nil)
        let flipped = BlockedList.Items(plan: plan([social], mode: .allow), categories: [social])
        #expect(BlockedList.differenceLine(setupName: "S", current: flipped, saved: saved)
                == "Differs from setup 'S': uses an allow list instead of a block list")
    }

    @Test func longListsAreCapped() {
        let many = FocusCategory(id: "m", name: "M", symbol: "x", apps: [], websites: (1...7).map { "s\($0).com" })
        let current = BlockedList.Items(plan: plan([many]), categories: [many])
        let line = BlockedList.differenceLine(setupName: "S", current: current,
                                              saved: BlockedList.Items(mode: .block, categories: []))
        #expect(line == "Differs from setup 'S': adds s1.com, s2.com, s3.com, s4.com and 3 more")
    }

    @Test func comparesWithTheLoadedSetupElseTheNearestAndNothingOnAnExactMatch() {
        let a = FocusSetup(minutes: 25, categoryIDs: ["social"], mode: .block, strict: false)
        let b = FocusSetup(minutes: 25, categoryIDs: ["mail"], mode: .block, strict: false)
        let current = BlockedList.Items(plan: plan(all), categories: all)
        // Loaded: that one, even when another is nearer.
        #expect(BlockedList.comparisonSetup(current: current, setups: [a, b], loadedSetupID: a.id, categories: all)?.id == a.id)
        // Not loaded: the nearest (mail holds 3 of the 4 items).
        #expect(BlockedList.comparisonSetup(current: current, setups: [a, b], loadedSetupID: nil, categories: all)?.id == b.id)
        // Exactly a saved setup: nothing to compare.
        let exact = BlockedList.Items(plan: plan([social]), categories: [social])
        #expect(BlockedList.comparisonSetup(current: exact, setups: [a, b], loadedSetupID: nil, categories: all) == nil)
        // No setups, or none sharing anything: nothing.
        #expect(BlockedList.comparisonSetup(current: current, setups: [], loadedSetupID: nil, categories: all) == nil)
        let apart = FocusCategory(id: "z", name: "Z", symbol: "x", apps: [], websites: ["z.com"])
        let zSetup = FocusSetup(minutes: 25, categoryIDs: ["z"], mode: .block, strict: false)
        #expect(BlockedList.comparisonSetup(current: current, setups: [zSetup], loadedSetupID: nil, categories: all + [apart]) == nil)
    }

    @Test func makeCombinesSectionsAndTheLine() {
        let setup = FocusSetup(minutes: 25, categoryIDs: ["social"], mode: .block, strict: false)
        let list = BlockedList.make(plan: plan(all), categories: all, setups: [setup], loadedSetupID: nil, allCategories: all)
        #expect(list.sections.count == 2)
        #expect(list.differenceLine == "Differs from setup 'New setup': adds Mail, gmail.com")
        let none = BlockedList.make(plan: plan(all), categories: all, setups: [], loadedSetupID: nil, allCategories: all)
        #expect(none.differenceLine == nil)
    }

    @Test func nothingIsBuiltWhileCollapsed() {
        var built = 0
        var state = LazyBlockedList()
        let make: () -> BlockedList? = { built += 1; return BlockedList(mode: .block, sections: [], differenceLine: nil) }
        state.setExpanded(false, build: make)
        #expect(built == 0 && state.list == nil)
        state.setExpanded(true, build: make)
        #expect(built == 1 && state.list != nil)
        state.setExpanded(false, build: make)
        #expect(built == 1 && state.list == nil)
        state.setExpanded(true, build: make)
        state.reset()
        #expect(built == 2 && !state.expanded && state.list == nil)
    }
}
