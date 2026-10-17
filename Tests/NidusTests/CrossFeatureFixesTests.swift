//
//  CrossFeatureFixesTests.swift
//  NidusTests
//
//  Where 0.4's features meet: a fixed end and a break with rules, a start
//  that hands over from one set of rules to another, a run of one setup, and
//  saved state edited by hand.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct CrossFeatureFixesTests {
    static let minute: TimeInterval = 60
    let categories = [FocusCategory(id: "social", name: "Social", symbol: "person.2", apps: [], websites: ["x.com"])]

    func defaults() -> StartDefaults {
        StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: categories,
                      defaultBreakRules: BreakRules(apps: ["com.tinyspeck.slackmacgap"]))
    }

    // MARK: A fixed end earns no break

    @Test func aFixedEndSettlesNoBreakInThePlan() throws {
        var scheduled = SessionRequest(goal: "", minutes: 30)
        scheduled.hasFixedEnd = true
        scheduled.breakMinutes = 10
        #expect(try #require(scheduled.resolved(with: defaults(), length: { (30, false) })?.plan).breakLength == 0)

        let meeting = try #require(SessionRequest(goal: "").resolved(with: defaults(), length: { (40, true) })?.plan)
        #expect(meeting.breakLength == 0, "until the next meeting: its start is the end")

        let ordinary = try #require(SessionRequest(goal: "", minutes: 30).resolved(with: defaults(), length: { (30, false) })?.plan)
        #expect(ordinary.breakLength == nil, "everything else keeps Settings' break, as before")
    }

    @Test func soNoBreakWithRulesBeginsOnlyToBeCalledOff() {
        let h = Harness()
        h.engine.breakLength = 10 * Self.minute
        var plan = SessionPlan(goal: "", duration: Self.minute, mode: .block, apps: [], websites: ["x.com"])
        plan.breakRules = BreakRules(apps: ["com.tinyspeck.slackmacgap"])
        plan.breakLength = 0
        h.engine.start(plan)
        h.clock.advance(Self.minute + 1)
        h.engine.tick()
        #expect(h.engine.breakState == nil)
        #expect(h.engine.enforcement == nil, "nothing quit or moved for a break that isn't coming")
    }

    // MARK: A start that hands over from rules to rules

    @Test func onlyAStartFromRulesToRulesTakesStockAfresh() {
        let restricted = Enforcement(mode: .block, apps: ["com.tinyspeck.slackmacgap"], websites: [])
        let onlyXcode = Enforcement(mode: .allow, apps: ["com.apple.dt.Xcode"], websites: [])
        #expect(FocusController.restartsBlocker(sessionStarted: true, from: restricted, to: onlyXcode),
                "a break with rules, then an allow list: what is open now is hidden, not quit")
        #expect(FocusController.restartsBlocker(sessionStarted: true, from: onlyXcode, to: onlyXcode),
                "a block straight after a block, the same rules")
        let snoozed = Enforcement(mode: .allow, apps: ["com.apple.dt.Xcode", "com.apple.Safari"], websites: [])
        #expect(!FocusController.restartsBlocker(sessionStarted: false, from: onlyXcode, to: snoozed),
                "a snooze mid-session keeps what was open at its start")
        #expect(!FocusController.restartsBlocker(sessionStarted: true, from: nil, to: onlyXcode), "from nothing it starts fresh anyway")
        #expect(!FocusController.restartsBlocker(sessionStarted: true, from: restricted, to: nil))
    }

    // MARK: A run of one setup opens its workspace once

    static func plan(goal: String, resources: [WorkspaceResource]) -> SessionPlan {
        var plan = SessionPlan(goal: goal, duration: 25 * minute, mode: .block, apps: [], websites: ["x.com"])
        plan.resources = resources
        return plan
    }

    @Test func aRunOfOneSetupOpensItsWorkspaceOnce() throws {
        let aims = [WorkspaceResource(kind: .webPage, displayName: "Aims", url: "https://example.com/aims")]
        let h = Harness()
        let run = SequenceRun(name: "Pomodoro", steps: [.work(Self.plan(goal: "Aims", resources: aims)),
                                                         .rest(length: 5 * Self.minute, rules: nil),
                                                         .work(Self.plan(goal: "Aims", resources: aims))],
                              startedAt: h.clock.now)
        #expect(h.engine.startSequence(run))
        #expect(h.engine.session?.plan.isContinuation == false, "the first block opens it")
        h.clock.advance(25 * Self.minute)
        h.engine.tick()
        #expect(try #require(h.engine.breakState).plan.isContinuation, "the same pages are still open")
        h.engine.skipBreak()
        #expect(h.engine.session?.plan.isContinuation == true)
        #expect(h.engine.session?.plan.sequenceStep?.index == 2)
    }

    @Test func aBlockWithItsOwnWorkspaceStillOpensIt() throws {
        let aims = [WorkspaceResource(kind: .webPage, displayName: "Aims", url: "https://example.com/aims")]
        let figures = [WorkspaceResource(kind: .webPage, displayName: "Figures", url: "https://example.com/figures")]
        let h = Harness()
        let run = SequenceRun(name: "Grant", steps: [.work(Self.plan(goal: "Aims", resources: aims)),
                                                      .work(Self.plan(goal: "Figures", resources: figures))],
                              startedAt: h.clock.now)
        #expect(h.engine.startSequence(run))
        h.clock.advance(25 * Self.minute)
        h.engine.tick()
        #expect(h.engine.session?.plan.goal == "Figures")
        #expect(h.engine.session?.plan.isContinuation == false)
        #expect(!SessionEngine.opensWhatIsOpen(Self.plan(goal: "", resources: []), then: Self.plan(goal: "", resources: [])),
                "nothing to open is never a continuation by this rule")
    }

    // MARK: State edited by hand

    @Test func aRunWhoseStepIsOutOfRangeIsDroppedOnRestore() {
        let store = MemoryStore()
        var run = SequenceRun(name: "Grant", steps: [.rest(length: 60, rules: nil)], startedAt: Date())
        run.index = -5
        store.record = SessionRecord(sequence: run)
        let engine = SessionEngine(store: store)
        engine.restore()
        #expect(engine.sequence == nil)
        #expect(NidusModel.plaqueSequence(run) == nil, "and the Plaque snapshot never indexes it")
    }

    @Test func aSequenceStepsMinutesAreHeldToADay() throws {
        let data = Data(#"{"id":"\#(UUID().uuidString)","name":"Huge","steps":[{"id":"\#(UUID().uuidString)","kind":"work","minutes":9223372036854775807},{"id":"\#(UUID().uuidString)","kind":"work","minutes":-4}]}"#.utf8)
        let sequence = try JSONDecoder().decode(FocusSequence.self, from: data)
        #expect(sequence.steps.map(\.minutes) == [24 * 60, 0])
        #expect(sequence.totalMinutes == 24 * 60, "no overflow in the sums")
    }
}
