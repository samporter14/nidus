//
//  SequenceTests.swift
//  NidusTests
//
//  0.4, sequences: the engine walking a resolved run (blocks, breaks, the end),
//  the controls that end or skip, what happens when Nidus or the Mac was away,
//  and the saved definition that resolves into a run. Fake clock and store;
//  no browser, app, Shortcut or real folder is touched.
//

import Foundation
import Testing
@testable import Nidus

/// A work block of a run: blocks something, so enforcement is visible.
private func block(_ goal: String, _ minutes: Double = 25, strict: Bool = false, site: String = "youtube.com",
                   breakRules: BreakRules? = nil) -> SessionPlan {
    var p = SessionPlan(goal: goal, duration: minutes * minute, mode: .block, apps: [], websites: [site])
    p.strict = strict
    p.breakRules = breakRules
    return p
}

private func run(_ steps: [SequenceStep], name: String = "Morning") -> SequenceRun {
    SequenceRun(name: name, steps: steps, startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
}

private let social = BreakRules(websites: ["x.com"], reminder: "Stretch")

@MainActor private func ended(_ events: EventLog) -> [(SessionEndReason, SessionState)] {
    events.all.compactMap { event in
        if case .ended(let reason, let state) = event { (reason, state) } else { nil }
    }
}

@MainActor
struct SequenceEngineTests {
    /// 40 min writing, a 10 min break that keeps x.com blocked, 25 min figures.
    private func writing(strict: Bool = false) -> SequenceRun {
        run([.work(block("Writing", 40, strict: strict, site: "youtube.com")),
             .rest(length: 10 * minute, rules: social),
             .work(block("Figures", 25, strict: strict, site: "reddit.com"))])
    }

    @Test func startingRunsTheFirstBlockStampedWithItsPlace() throws {
        let h = Harness()
        let r = writing()
        #expect(h.engine.startSequence(r))
        #expect(h.engine.sequence?.id == r.id)
        #expect(h.engine.isInSequence)
        let plan = try #require(h.engine.session?.plan)
        #expect(plan.goal == "Writing")
        #expect(plan.sequenceStep == SequenceStepRef(runID: r.id, index: 0, count: 3))
        #expect(h.engine.remaining == 40 * minute)
        #expect(h.engine.enforcement?.websites == ["youtube.com"])
        #expect(h.events.all == [.started])
    }

    @Test func aRunWithoutAWorkBlockFirstDoesNotStart() {
        let h = Harness()
        #expect(!h.engine.startSequence(run([.rest(length: 60, rules: nil), .work(block("A"))])))
        #expect(!h.engine.startSequence(run([])))
        #expect(h.engine.session == nil && h.engine.sequence == nil && h.events.all.isEmpty)
    }

    @Test func itNeverEndsOrReplacesWhatIsOn() {
        let h = Harness()
        h.engine.start(plan(25))
        #expect(!h.engine.startSequence(writing()), "only the model's guarded path starts one, and it checks first; the engine does too")
        #expect(h.engine.session?.plan == plan(25))
        #expect(h.events.all == [.started])

        let h2 = Harness()
        h2.engine.breakLength = 5 * minute
        h2.engine.start(plan(25))
        h2.clock.advance(25 * minute)
        h2.engine.tick()
        #expect(h2.engine.isOnBreak)
        #expect(!h2.engine.startSequence(writing()))
        #expect(h2.engine.isOnBreak && h2.engine.sequence == nil)
    }

    @Test func workThenBreakThenWorkThenFinish() throws {
        let h = Harness()
        let r = writing()
        h.engine.startSequence(r)
        h.clock.advance(40 * minute)
        h.engine.tick()

        // The break between: its own length and rules, the next block waiting.
        #expect(h.engine.session == nil)
        let pause = try #require(h.engine.breakState)
        #expect(pause.length == 10 * minute)
        #expect(pause.rules == social)
        #expect(pause.plan.goal == "Figures")
        #expect(pause.plan.sequenceStep == SequenceStepRef(runID: r.id, index: 2, count: 3))
        #expect(!pause.plan.isContinuation, "the next block is new work, not the last one resumed")
        #expect(h.engine.enforcement == Enforcement(mode: .block, apps: [], websites: ["x.com"]))
        #expect(h.engine.isInSequence)
        guard case .ended(.completed, _)? = h.events.last else { Issue.record("expected the first block to end"); return }

        h.clock.advance(10 * minute)
        h.engine.tick()
        #expect(h.engine.session?.plan.goal == "Figures")
        #expect(h.engine.remaining == 25 * minute)
        #expect(h.engine.enforcement?.websites == ["reddit.com"])
        #expect(h.engine.sequence?.index == 2)
        #expect(h.events.last == .started)

        // The last block: the run is over, and no break follows it.
        h.engine.breakLength = 5 * minute
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(h.engine.session == nil && !h.engine.isOnBreak && h.engine.sequence == nil)
        #expect(!h.engine.isInSequence)
        #expect(h.engine.enforcement == nil)
        guard case .ended(.completed, let final)? = h.events.last else { Issue.record("expected a completed end"); return }
        #expect(final.plan.goal == "Figures")
    }

    @Test func noOrdinaryBreakIsEverAddedInARun() {
        let h = Harness()
        h.engine.breakLength = 5 * minute
        var first = block("A", 25)
        first.breakLength = 15 * minute
        first.breakRules = social
        h.engine.startSequence(run([.work(first), .work(block("B", 25))]))
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(!h.engine.isOnBreak, "a block straight after a block has nothing between, whatever Settings says")
        #expect(h.engine.session?.plan.goal == "B")
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(!h.engine.isOnBreak && h.engine.session == nil, "and the last block earns none")
    }

    @Test func aBlockStraightAfterABlockSeesOneChangeOfRules() {
        let h = Harness()
        let r = run([.work(block("A", 25, site: "youtube.com")), .work(block("B", 25, site: "reddit.com"))])
        var seen: [Enforcement?] = []
        h.engine.onEvent = { [unowned engine = h.engine] _ in seen.append(engine.enforcement) }
        h.engine.startSequence(r)
        seen.removeAll()
        h.clock.advance(25 * minute)
        h.engine.tick()
        // .ended then .started, and both already see the next block's rule:
        // the blockers never see a moment with nothing blocked in between.
        #expect(seen.count == 2)
        #expect(seen.allSatisfy { $0?.websites == ["reddit.com"] })
    }

    @Test func aBreakOfNoLengthIsSkipped() {
        let h = Harness()
        h.engine.startSequence(run([.work(block("A", 25)), .rest(length: 0, rules: social), .work(block("B", 25))]))
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
        #expect(h.engine.session?.plan.goal == "B")
    }

    @Test func exactlyOneHistoryEntryPerBlockWithItsPlace() throws {
        let h = Harness()
        let r = run([.work(block("A", 25)), .rest(length: 5 * minute, rules: nil), .work(block("B", 25)),
                     .work(block("C", 25))])
        h.engine.startSequence(r)
        for length in [25.0, 5.0, 25.0, 25.0] {
            h.clock.advance(length * minute)
            h.engine.tick()
        }
        let entries = ended(h.events).compactMap { SessionEntry(ended: $0.1, outcome: $0.0) }
        #expect(entries.count == 3, "three blocks, each recorded once, the break not at all")
        #expect(entries.map(\.goal) == ["A", "B", "C"])
        #expect(entries.map { $0.sequenceStep?.index } == [0, 2, 3])
        #expect(entries.allSatisfy { $0.sequenceStep?.runID == r.id && $0.sequenceStep?.count == 4 })
        #expect(entries.allSatisfy { $0.focused == 25 * minute }, "break time is never focus time")
    }

    // MARK: Controls

    @Test func skippingABreakStartsTheNextBlockNow() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(40 * minute)
        h.engine.tick()
        h.clock.advance(3 * minute)
        h.engine.skipBreak()
        #expect(!h.engine.isOnBreak)
        #expect(h.engine.session?.plan.goal == "Figures")
        #expect(h.engine.remaining == 25 * minute)
        #expect(h.engine.sequence?.index == 2)
        #expect(h.engine.session?.plan.isContinuation == false)
        #expect(h.engine.enforcement?.websites == ["reddit.com"], "the break's rules are released")
    }

    @Test func endingABreakEndsTheRun() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(40 * minute)
        h.engine.tick()
        h.engine.endBreak()
        #expect(!h.engine.isOnBreak && h.engine.session == nil)
        #expect(h.engine.sequence == nil)
        #expect(h.engine.enforcement == nil)
        #expect(h.events.last == .breakEnded)
        h.clock.advance(60 * minute)
        h.engine.tick()
        #expect(h.engine.session == nil, "no next block ever follows")
    }

    @Test func endingANonStrictBlockEndsTheRunWithNoBreak() {
        let h = Harness()
        h.engine.breakLength = 5 * minute
        h.engine.startSequence(writing())
        h.clock.advance(10 * minute)
        h.engine.end()
        #expect(h.engine.session == nil && !h.engine.isOnBreak)
        #expect(h.engine.sequence == nil)
        guard case .ended(.endedEarly, let final)? = h.events.last else { Issue.record("no early end"); return }
        #expect(final.plan.sequenceStep?.index == 0, "recorded once, as the block it was")
        h.clock.advance(60 * minute)
        h.engine.tick()
        #expect(h.engine.session == nil)
    }

    @Test func aStrictBlockHasNoControlThatPausesSkipsOrShortensIt() {
        let h = Harness()
        h.engine.startSequence(writing(strict: true))
        h.engine.pause()
        #expect(h.engine.isRunning, "strict: no pause")
        h.engine.snooze("youtube.com")
        #expect(h.engine.session?.snoozes.isEmpty == true)
        // The break controls act on a break, never on a block.
        h.engine.skipBreak()
        h.engine.endBreak()
        #expect(h.engine.session?.plan.goal == "Writing")
        #expect(h.engine.remaining == 40 * minute)
        #expect(h.engine.isInSequence)
        // A second sequence cannot replace it either.
        #expect(!h.engine.startSequence(writing()))
        #expect(h.engine.session?.plan.goal == "Writing")
    }

    @Test func aStrictBlockIsEndedOnlyByTheStrictGateAndThatEndsTheRun() {
        // The popover's gate calls end() after the phrase; nothing new adds a way around it.
        let h = Harness()
        h.engine.startSequence(writing(strict: true))
        h.engine.end()
        #expect(h.engine.session == nil && h.engine.sequence == nil && !h.engine.isOnBreak)
    }

    @Test func startingSomethingElseLeavesTheRunBehind() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.engine.start(plan(25))
        #expect(h.engine.sequence == nil)
        #expect(h.engine.session?.plan.sequenceStep == nil)
        h.clock.advance(25 * minute)
        h.engine.breakLength = 5 * minute
        h.engine.tick()
        #expect(h.engine.isOnBreak, "an ordinary session gets the ordinary break again")
    }

    @Test func anAgainOfAFinishedBlockStartsAPlainSession() throws {
        let h = Harness()
        h.engine.startSequence(writing())
        h.engine.end()
        let last = try #require(h.engine.lastPlan)
        #expect(last.sequenceStep != nil)
        h.engine.start(last)
        #expect(h.engine.session?.plan.sequenceStep == nil)
        #expect(h.engine.sequence == nil)
    }

    // MARK: Sleep, lock, restart, away

    @Test func sleepAndLockPauseABlockAsToday() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(10 * minute)
        h.engine.systemWillSleep()
        #expect(h.engine.isPaused)
        h.clock.advance(5 * 60 * minute)    // the lid stays shut all night
        h.engine.tick()
        #expect(h.engine.session != nil && h.engine.isInSequence, "a paused block does not run out")
        #expect(h.engine.enforcement != nil, "a pause for being away keeps blocking")
        h.engine.systemDidWake()
        #expect(h.engine.isRunning)
        #expect(h.engine.remaining == 30 * minute)
        h.clock.advance(30 * minute)
        h.engine.tick()
        #expect(h.engine.isOnBreak, "then the run goes on to its break")
    }

    @Test func aRestartMidBlockResumesTheRun() throws {
        let h = Harness()
        let r = writing()
        h.engine.startSequence(r)
        h.clock.advance(15 * minute)
        let (engine, _) = h.relaunch()
        #expect(engine.sequence?.id == r.id)
        #expect(engine.remaining == 25 * minute)
        #expect(engine.session?.plan.sequenceStep?.index == 0)
        h.clock.advance(25 * minute)
        engine.tick()
        #expect(engine.isOnBreak, "it carries on to the break as if it had never quit")
        #expect(engine.breakState?.plan.goal == "Figures")
    }

    @Test func aRestartMidBreakResumesIt() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(40 * minute)
        h.engine.tick()
        h.clock.advance(4 * minute)
        let (engine, _) = h.relaunch()
        #expect(engine.isOnBreak && engine.sequence != nil)
        #expect(engine.breakRemaining == 6 * minute)
        #expect(engine.enforcement?.websites == ["x.com"])
        h.clock.advance(6 * minute)
        engine.tick()
        #expect(engine.session?.plan.goal == "Figures")
        #expect(engine.sequence?.index == 2)
    }

    @Test func aBreakThatRanOutLongAgoEndsTheRunWithoutReplaying() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(40 * minute)
        h.engine.tick()
        h.clock.advance(10 * minute + SessionEngine.breakGrace + 1)
        let (engine, events) = h.relaunch()
        engine.tick()
        #expect(!engine.isOnBreak && engine.session == nil && engine.sequence == nil)
        #expect(events.last == .breakEnded)
        #expect(engine.enforcement == nil)
    }

    @Test func aBreakThatJustRanOutStillStartsTheNextBlock() {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(40 * minute)
        h.engine.tick()
        h.clock.advance(10 * minute + SessionEngine.breakGrace)
        h.engine.tick()
        #expect(h.engine.session?.plan.goal == "Figures")
    }

    @Test func aBlockThatExpiredWhileAwayIsRecordedAndEndsTheRun() throws {
        let h = Harness()
        h.engine.startSequence(writing())
        h.clock.advance(20 * minute)
        h.engine.checkpoint()
        h.clock.advance(5 * 60 * minute)    // Nidus was not running
        let (engine, events) = h.relaunch()
        #expect(engine.session == nil && !engine.isOnBreak && engine.sequence == nil, "the missed blocks are not replayed")
        guard case .ended(.expiredWhileAway, let final)? = events.last else {
            Issue.record("expected expiredWhileAway, got \(String(describing: events.last))"); return
        }
        #expect(final.plan.sequenceStep?.index == 0)
        #expect(final.focusedTime == 20 * minute, "all that is known of it")
        #expect(engine.enforcement == nil)
    }

    @Test func aRunWhoseRecordNoLongerMatchesItsBlockIsLetGo() {
        let h = Harness()
        h.engine.startSequence(writing())
        // The saved block is another run's.
        var record = h.store.record!
        record.sequence?.id = UUID()
        h.store.record = record
        let (engine, _) = h.relaunch()
        #expect(engine.session != nil)
        #expect(engine.sequence == nil, "the block carries on as an ordinary session")
        engine.breakLength = 5 * minute
        h.clock.advance(40 * minute)
        engine.tick()
        #expect(!engine.isOnBreak, "and, tied to a run it can't find, earns no ordinary break")
    }

    @Test func aRunIsSavedWithTheBlockAndTheBreak() throws {
        let h = Harness()
        let r = writing()
        h.engine.startSequence(r)
        #expect(h.store.record?.sequence?.id == r.id)
        h.clock.advance(40 * minute)
        h.engine.tick()
        #expect(h.store.record?.sequence?.index == 1)
        #expect(h.store.record?.pendingBreak?.rules == social)
    }
}

// MARK: - The saved definition

@MainActor
struct FocusSequenceTests {
    private let slack = "com.tinyspeck.slackmacgap"
    private let xcode = FocusCategory(id: "xcode", name: "Xcode", symbol: "hammer",
                                      apps: [BlockedApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")], websites: [])
    private var categories: [FocusCategory] { FocusCategory.presets + [xcode] }

    private func defaults(breakRules: BreakRules? = nil) -> StartDefaults {
        StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: categories, defaultBreakRules: breakRules,
                      projectName: { _ in "R01 renewal" })
    }

    private func context(setups: [FocusSetup] = []) -> FocusSequence.Context {
        FocusSequence.Context(setups: setups, categories: categories, mode: .block, selectedCategoryIDs: ["social"])
    }

    private func resolve(_ sequence: FocusSequence, setups: [FocusSetup] = [], breakRules: BreakRules? = nil) -> SequenceRun? {
        let d = defaults(breakRules: breakRules)
        return sequence.resolved(startedAt: Date(), request: {
            sequence.request(for: $0, setups: setups, categories: categories, projectExists: { _ in true })
        }, plan: { $0.resolved(with: d, length: { (25, false) })?.plan })
    }

    @Test func aSummaryNamesEachStep() {
        let sequence = FocusSequence(name: "Grant", steps: [.work(minutes: 40, goal: "writing"), .rest(minutes: 10),
                                                            .work(minutes: 25, goal: "figures")])
        #expect(sequence.summary(setups: []) == "40 min writing \u{2192} 10 min break \u{2192} 25 min figures")
        #expect(sequence.totals() == "2 blocks \u{00B7} 1 hr 5 min of work \u{00B7} 1 hr 15 min in all")
        let setup = FocusSetup(name: "Deep work", categoryIDs: ["social"])
        let unnamed = FocusSequence(steps: [.work(minutes: 90, setupID: setup.id), .work(minutes: 15)])
        #expect(unnamed.summary(setups: [setup]) == "1 hr 30 min Deep work \u{2192} 15 min focus")
    }

    @Test func aLengthOfNothingIsNeverCalledOpenEnded() {
        let sequence = FocusSequence(steps: [.work(minutes: 0, goal: "a")])
        #expect(sequence.summary(setups: []) == "0 min a")
        #expect(sequence.totals() == "1 block \u{00B7} 0 min of work")
    }

    @Test func aGoodOneHasNoProblems() {
        #expect(FocusSequence.starter().problems(in: context()).isEmpty)
    }

    @Test func theChecksNameWhatIsWrong() {
        let work = FocusSequence.Step.work(), rest = FocusSequence.Step.rest()
        #expect(FocusSequence(steps: []).problems(in: context()) == [.noWorkBlock])
        #expect(FocusSequence(steps: [rest]).problems(in: context()).contains(.noWorkBlock))
        #expect(FocusSequence(steps: [rest, work]).problems(in: context()) == [.startsWithBreak])
        #expect(FocusSequence(steps: [work, rest]).problems(in: context()) == [.endsWithBreak])
        #expect(FocusSequence(steps: [work, rest, .rest(), work]).problems(in: context()) == [.breaksInARow(step: 3)])
        #expect(FocusSequence(steps: [.work(minutes: 0)]).problems(in: context()) == [.lengthOutOfRange(step: 1)],
                "0 would be open-ended, and a sequence must be finite")
        #expect(FocusSequence(steps: [.work(minutes: 24 * 60 + 1)]).problems(in: context()) == [.lengthOutOfRange(step: 1)])
        #expect(FocusSequence(steps: [work, .rest(minutes: 0), work]).problems(in: context()) == [.lengthOutOfRange(step: 2)])
    }

    @Test func aStepsSetupMustExistAndBeAbleToStart() {
        let gone = FocusSequence(steps: [.work(setupID: UUID())])
        #expect(gone.problems(in: context()) == [.setupGone(step: 1)])
        let broken = FocusSetup(name: "Old", categoryIDs: ["deleted"])
        let bad = FocusSequence(steps: [.work(setupID: broken.id)])
        #expect(bad.problems(in: context(setups: [broken])) == [.setupCannotStart(step: 1, reason: "Its categories are gone")])
        let fine = FocusSetup(name: "Fine", categoryIDs: ["social"])
        #expect(FocusSequence(steps: [.work(setupID: fine.id)]).problems(in: context(setups: [fine])).isEmpty)
    }

    @Test func aStepWithNoSetupNeedsSomethingToBlockInThePopover() {
        var nothing = context()
        nothing.selectedCategoryIDs = []
        #expect(FocusSequence.starter().problems(in: nothing) == [.nothingToBlock(step: 1), .nothingToBlock(step: 3)])
        nothing.mode = .allow
        #expect(FocusSequence.starter().problems(in: nothing).isEmpty, "an allow list blocks everything else")
    }

    @Test func resolvingMakesFullPlansThroughTheSameResolutionAsAnyStart() throws {
        let setup = FocusSetup(name: "Deep work", minutes: 90, categoryIDs: ["xcode"], mode: .allow, strict: true, goal: "Saved goal")
        let project = UUID()
        let sequence = FocusSequence(steps: [.work(minutes: 40, goal: "Write", setupID: setup.id, projectID: project),
                                             .rest(minutes: 10),
                                             .work(minutes: 25)])
        let run = try #require(resolve(sequence, setups: [setup]))
        #expect(run.steps.count == 3 && run.sequenceID == sequence.id)
        guard case .work(let first) = run.steps[0], case .work(let third) = run.steps[2] else { Issue.record("shape"); return }
        // The first through the setup: its mode, strictness and categories, the step's goal and length.
        #expect(first.mode == .allow && first.strict)
        #expect(first.apps == ["com.apple.dt.Xcode"])
        #expect(first.goal == "Write" && first.duration == 40 * minute)
        #expect(first.setupID == setup.id)
        #expect(first.projectID == project && first.projectName == "R01 renewal")
        // The third has no setup: the popover's choices.
        #expect(third.mode == .block && !third.strict)
        #expect(third.websites.contains("x.com"))
        #expect(third.duration == 25 * minute && third.goal.isEmpty)
        // The same plan the request alone would make.
        let direct = try #require(sequence.request(for: sequence.steps[0], setups: [setup], categories: categories, projectExists: { _ in true })
            .resolved(with: defaults(), length: { (25, false) })?.plan)
        var expected = direct
        expected.sequenceStep = run.ref(at: 0)
        #expect(first == expected)
        #expect(third.sequenceStep == run.ref(at: 2))
    }

    @Test func aBlockWhoseSetupHasAGoalUsesItWhenTheStepHasNone() throws {
        let setup = FocusSetup(name: "Writing", categoryIDs: ["social"], goal: "Draft")
        let run = try #require(resolve(FocusSequence(steps: [.work(setupID: setup.id)]), setups: [setup]))
        guard case .work(let plan) = run.steps[0] else { return }
        #expect(plan.goal == "Draft")
    }

    @Test func aDeletedProjectStartsTheBlockWithNone() throws {
        let sequence = FocusSequence(steps: [.work(projectID: UUID())])
        let d = defaults()
        let run = try #require(sequence.resolved(startedAt: Date(), request: {
            sequence.request(for: $0, setups: [], categories: categories, projectExists: { _ in false })
        }, plan: { $0.resolved(with: d, length: { (25, false) })?.plan }))
        guard case .work(let plan) = run.steps[0] else { return }
        #expect(plan.projectID == nil && plan.projectName == nil)
    }

    @Test func aBlockThatWouldBlockNothingStopsTheWholeStart() {
        let empty = FocusSetup(name: "Empty", categoryIDs: [])
        #expect(resolve(FocusSequence(steps: [.work(), .rest(), .work(setupID: empty.id)]), setups: [empty]) == nil)
    }

    @Test func aBreaksRulesAreInheritedNoneOrItsOwn() throws {
        let socialRules = BreakRules(websites: ["x.com"])
        let own = BreakRules(apps: [slack], reminder: "Walk")
        let withRules = FocusSetup(name: "Rules", categoryIDs: ["social"])
        _ = withRules
        func rules(_ choice: FocusSequence.Step.BreakChoice, defaultRules: BreakRules?) throws -> BreakRules? {
            let run = try #require(resolve(FocusSequence(steps: [.work(), .rest(rules: choice), .work()]), breakRules: defaultRules))
            guard case .rest(_, let rules) = run.steps[1] else { Issue.record("not a break"); return nil }
            return rules
        }
        #expect(try rules(.inherit, defaultRules: socialRules) == socialRules, "the next block's plan, which took Settings' default")
        #expect(try rules(.inherit, defaultRules: nil) == nil)
        #expect(try rules(.none, defaultRules: socialRules) == nil)
        #expect(try rules(.own(own), defaultRules: socialRules) == own)
    }

    @Test func aRunIsASnapshotEditingTheSavedSequenceChangesNothing() throws {
        var sequence = FocusSequence(name: "Grant", steps: [.work(minutes: 40, goal: "writing"), .rest(minutes: 10),
                                                            .work(minutes: 25, goal: "figures")])
        let run = try #require(resolve(sequence))
        let h = Harness()
        #expect(h.engine.startSequence(run))
        // Edited while it runs: renamed, relengthened, a block removed.
        sequence.name = "Renamed"
        sequence.steps[0].minutes = 5
        sequence.steps.removeLast()
        #expect(h.engine.sequence == run)
        #expect(h.engine.sequence?.name == "Grant")
        h.clock.advance(40 * minute)
        h.engine.tick()
        #expect(h.engine.breakState?.length == 10 * minute)
        #expect(h.engine.breakState?.plan.goal == "figures")
        #expect(h.engine.breakState?.plan.duration == 25 * minute)
    }

    @Test func aSavedSequenceRoundTripsAndABadStepLosesOnlyItself() throws {
        let sequence = FocusSequence(name: "Grant", steps: [.work(minutes: 40, goal: "writing", projectID: UUID()),
                                                            .rest(minutes: 10, rules: .own(BreakRules(websites: ["x.com"], reminder: "Walk"))),
                                                            .rest(minutes: 5, rules: .none),
                                                            .work(minutes: 25)])
        let decoded = try JSONDecoder().decode(FocusSequence.self, from: JSONEncoder().encode(sequence))
        #expect(decoded == sequence)

        let id = UUID()
        let json = #"""
        [{"id":"\#(id)","name":"Kept","steps":[{"id":"\#(UUID())","kind":"work","minutes":30,"goal":"A","extra":1},
                                                {"kind":"sideways"},
                                                {"id":"\#(UUID())","kind":"rest","minutes":"ten","rules":{"mode":"own","rules":7}}]},
         {"name":"No id"},
         {"id":"\#(UUID())","name":"Also kept","steps":"no"}]
        """#
        let list = try #require(LossyJSON.list(FocusSequence.self, from: Data(json.utf8)))
        #expect(list.map(\.name) == ["Kept", "Also kept"], "one bad sequence does not wipe the rest")
        #expect(list[0].steps.count == 2, "the step without an id or a kind is dropped")
        #expect(list[0].steps[0].minutes == 30 && list[0].steps[0].goal == "A")
        #expect(list[0].steps[1].minutes == 10, "a field written wrongly falls back alone")
        #expect(list[0].steps[1].rules == .own(BreakRules()))
        #expect(list[1].steps.isEmpty)
    }

    @Test func stepsMoveAndStopAtTheEnds() {
        let steps = [FocusSequence.Step.work(goal: "a"), .rest(), .work(goal: "c")]
        #expect(FocusSequence.moving(steps[2].id, by: -1, in: steps).map(\.id) == [steps[0].id, steps[2].id, steps[1].id])
        #expect(FocusSequence.moving(steps[0].id, by: -1, in: steps) == steps)
        #expect(FocusSequence.moving(steps[2].id, by: 1, in: steps) == steps)
        #expect(FocusSequence.moving(UUID(), by: 1, in: steps) == steps)
    }

    @Test func theResolutionIsTheOneEveryStartUses() throws {
        // Settings' break rules, length and strictness land in a request's plan.
        var d = defaults(breakRules: BreakRules(websites: ["x.com"]))
        d.strict = true
        let plan = try #require(SessionRequest(goal: "  Aims  ", minutes: 30).resolved(with: d, length: { (99, false) })?.plan)
        #expect(plan.goal == "Aims" && plan.duration == 30 * minute && plan.strict)
        #expect(plan.breakRules == BreakRules(websites: ["x.com"]))
        #expect(plan.breakLength == d.defaultBreakLength, "Settings' break length is frozen at start")
        // The length is asked only when none is given.
        var asked = false
        _ = SessionRequest(goal: "x", minutes: 10).resolved(with: d, length: { asked = true; return (1, false) })
        #expect(!asked)
        let resolved = try #require(SessionRequest(goal: "x").resolved(with: d, length: { (45, true) }))
        #expect(resolved.plan.duration == 45 * minute && resolved.endsAtMeeting)
        // A block list that blocks nothing is refused, an allow list is not.
        var none = d
        none.selectedCategoryIDs = []
        #expect(SessionRequest(goal: "x", minutes: 10).resolved(with: none, length: { (1, false) }) == nil)
        #expect(SessionRequest(goal: "x", minutes: 10, mode: .allow).resolved(with: none, length: { (1, false) }) != nil)
    }
}

// MARK: - Saying where a run is

struct SequenceLineTests {
    private func three() -> SequenceRun {
        var r = run([.work(block("Writing", 40)), .rest(length: 10 * minute, rules: nil), .work(block("Figures", 25))])
        r.index = 0
        return r
    }

    @Test func theLineWhileABlockRunsNamesWhatIsNext() {
        var r = three()
        #expect(r.progressLine == "Block 1 of 2 \u{00B7} next: 10 min break")
        r.index = 2
        #expect(r.progressLine == "Block 2 of 2 \u{00B7} next: last block")
        let direct = run([.work(block("A", 25)), .work(block("Figures", 30))])
        #expect(direct.progressLine == "Block 1 of 2 \u{00B7} next: 30 min Figures")
    }

    @Test func theLineOnABreakNamesTheNextBlock() {
        var r = three()
        r.index = 1
        #expect(r.progressLine == "Next: 25 min Figures")
    }

    @Test func aGoallessBlockIsJustABlock() {
        let r = run([.work(block("A", 25)), .work(block("", 15))])
        #expect(r.progressLine == "Block 1 of 2 \u{00B7} next: 15 min block")
    }

    @Test func theStepsAfterOneAreFoundAcrossBreaksAndStopAtTheEnd() throws {
        let r = three()
        let next = try #require(r.nextBlock())
        #expect(next.index == 2 && next.rest?.length == 10 * minute && next.plan.goal == "Figures")
        var last = r
        last.index = 2
        #expect(last.nextBlock() == nil)
        // A break at the end has no block after it and is not taken.
        let trailing = run([.work(block("A", 25)), .rest(length: 60, rules: nil)])
        #expect(trailing.nextBlock() == nil)
        // Breaks in a row are the first one.
        let doubled = run([.work(block("A", 25)), .rest(length: 60, rules: nil), .rest(length: 600, rules: nil), .work(block("B", 25))])
        let after = try #require(doubled.nextBlock())
        #expect(after.index == 3 && after.rest?.length == 60)
    }
}
