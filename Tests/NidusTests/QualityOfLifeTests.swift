//
//  QualityOfLifeTests.swift
//  NidusTests
//
//  Undo after ending early, the reminder for a pause that was forgotten, and
//  the +5 variants. Fake clock and store; nothing blocks, opens or runs.
//

import Foundation
import Testing
@testable import Nidus

private func qlPlan(_ minutes: Double? = 25, strict: Bool = false, site: String = "youtube.com") -> SessionPlan {
    var p = SessionPlan(goal: "Write the report", duration: minutes.map { $0 * minute }, mode: .block,
                        apps: ["com.example.chat"], websites: [site])
    p.strict = strict
    return p
}

@MainActor
private func lastEnd(_ events: EventLog) -> (SessionEndReason, SessionState)? {
    events.all.reversed().compactMap { event -> (SessionEndReason, SessionState)? in
        if case .ended(let reason, let state) = event { (reason, state) } else { nil }
    }.first
}

// MARK: - Undo after End

@MainActor
struct UndoEndEngineTests {
    @Test func undoBringsBackTheSameSessionWithItsDeadlineSnoozesAndEnforcement() throws {
        let h = Harness()
        var plan = qlPlan(25)
        plan.launchApps = ["com.example.editor"]
        h.engine.start(plan)
        let startedAt = try #require(h.engine.session?.startedAt)
        h.clock.advance(5 * minute)
        h.engine.snooze("youtube.com")
        h.engine.recordBlock("com.example.chat", name: "Chat")
        let before = try #require(h.engine.session)
        let enforcementBefore = h.engine.enforcement
        h.engine.end()
        #expect(h.engine.session == nil && h.engine.enforcement == nil)
        #expect(h.engine.canUndoEnd)

        h.clock.advance(3)
        #expect(h.engine.undoEnd())
        let after = try #require(h.engine.session)
        #expect(after.plan == before.plan)
        #expect(after.startedAt == startedAt)
        #expect(after.phase == before.phase, "the same absolute deadline")
        #expect(after.snoozes == before.snoozes)
        #expect(after.blocks == before.blocks)
        #expect(after.endedAt == nil && after.focusedTime == nil)
        #expect(h.engine.enforcement == enforcementBefore, "blocking is back, snooze and all")
        #expect(h.events.last == .undone)
        // The 3 seconds ended count as focus: the clock never stopped.
        #expect(h.engine.remaining == 20 * minute - 3)
        #expect(h.engine.elapsed == 5 * minute + 3)
        #expect(h.engine.lastPlan == plan)
        #expect(h.store.record?.session?.startedAt == startedAt, "saved, so a relaunch resumes it")
        #expect(!h.engine.canUndoEnd, "one undo per end")
        #expect(!h.engine.undoEnd())
    }

    @Test func aSessionEndedWhilePausedComesBackPausedWithTheSameTimeLeft() throws {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.clock.advance(10 * minute)
        h.engine.pause()
        h.clock.advance(minute)
        h.engine.end()
        h.clock.advance(2)
        #expect(h.engine.undoEnd())
        #expect(h.engine.isPaused)
        #expect(h.engine.remaining == 15 * minute)
        #expect(h.engine.enforcement == nil, "a pause the user chose blocks nothing")
    }

    @Test func undoWorksForFiveSecondsAndNotAfter() {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.engine.end()
        h.clock.advance(SessionEngine.undoWindow)
        #expect(h.engine.canUndoEnd, "the fifth second is still in")
        h.clock.advance(0.01)
        #expect(!h.engine.canUndoEnd)
        #expect(!h.engine.undoEnd())
        #expect(h.engine.session == nil)
        #expect(h.events.all.filter { $0 == .undone }.isEmpty)
    }

    @Test func aStrictSessionIsNeverBroughtBack() {
        let h = Harness()
        h.engine.start(qlPlan(25, strict: true))
        h.engine.end()   // the engine's end is what the strict gate leads to
        #expect(!h.engine.canUndoEnd)
        #expect(!h.engine.undoEnd())
        #expect(h.engine.session == nil)
    }

    @Test func aCompletedOrExpiredEndIsNotUndoable() {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        guard case .ended(.completed, _)? = h.events.last else { Issue.record("not completed"); return }
        #expect(!h.engine.canUndoEnd && !h.engine.undoEnd())

        let h2 = Harness()
        h2.engine.start(qlPlan(25))
        h2.clock.advance(30 * minute)
        let (relaunched, events) = h2.relaunch()
        guard case .ended(.expiredWhileAway, _)? = events.last else { Issue.record("not expired"); return }
        #expect(!relaunched.canUndoEnd && !relaunched.undoEnd())
    }

    @Test func aDeadlineThatPassedWhileEndedCannotBeUndone() {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.clock.advance(25 * minute - 3)
        h.engine.end()
        h.clock.advance(4)
        #expect(!h.engine.canUndoEnd, "it would only end again at once")
    }

    @Test func nothingElseMayHaveStartedMeanwhile() {
        // Another session.
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.engine.end()
        h.engine.start(qlPlan(10, site: "reddit.com"))
        #expect(!h.engine.canUndoEnd && !h.engine.undoEnd())
        #expect(h.engine.remaining == 10 * minute, "the new session is left alone")

        // A break.
        let b = Harness()
        b.engine.start(qlPlan(25))
        b.engine.end()
        b.engine.startBreak(plan: qlPlan(25), length: 5 * minute)
        #expect(!b.engine.canUndoEnd && !b.engine.undoEnd())
        #expect(b.engine.isOnBreak && b.engine.session == nil)

        // Ending the next one: only the latest end is undoable.
        let c = Harness()
        c.engine.start(qlPlan(25))
        c.engine.end()
        c.engine.start(qlPlan(10, site: "reddit.com"))
        c.engine.end()
        #expect(c.engine.undoEnd())
        #expect(c.engine.session?.plan.websites == ["reddit.com"])
    }

    @Test func startingOverARunningSessionOffersNoUndo() {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.engine.start(qlPlan(50))
        #expect(!h.engine.canUndoEnd, "only a deliberate End is taken back")
    }

    @Test func undoMakesNoBreakButTheRealEndStillEarnsOne() {
        let h = Harness()
        h.engine.breakLength = 5 * minute
        h.engine.start(qlPlan(25))
        h.clock.advance(2 * minute)
        h.engine.end()
        #expect(!h.engine.isOnBreak, "ending early earns no break")
        #expect(h.engine.undoEnd())
        #expect(!h.engine.isOnBreak)
        h.clock.advance(23 * minute)
        h.engine.tick()
        #expect(h.engine.isOnBreak, "completing it later earns the break as usual")
        guard case .ended(.completed, let final)? = h.events.last else { Issue.record("not completed"); return }
        #expect(final.focusedTime == 25 * minute, "focus time includes the seconds that were ended")
    }

    @Test func aBlockOfASequenceIsNotOfferedUndo() throws {
        let h = Harness()
        let run = SequenceRun(name: "Morning", steps: [.work(qlPlan(40)), .rest(length: 10 * minute, rules: nil), .work(qlPlan(25))],
                              startedAt: h.clock.now)
        #expect(h.engine.startSequence(run))
        h.engine.end()
        #expect(h.engine.sequence == nil, "ending a block ends the run, as before")
        #expect(!h.engine.canUndoEnd && !h.engine.undoEnd())
        #expect(h.engine.session == nil && !h.engine.isOnBreak)
    }

    @Test func aRelaunchWithinTheWindowLosesTheUndoOnly() {
        let h = Harness()
        h.engine.start(qlPlan(25))
        h.engine.end()
        let (relaunched, _) = h.relaunch()
        #expect(relaunched.session == nil)
        #expect(!relaunched.canUndoEnd && !relaunched.undoEnd())
    }
}

@MainActor
struct UndoEndControllerTests {
    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-undo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A plan that blocks nothing on this Mac.
    private func quiet(_ minutes: Double = 25) -> SessionPlan {
        SessionPlan(goal: "Write the report", duration: minutes * minute, mode: .block, apps: [], websites: [])
    }

    @Test func historyHoldsTheSessionOnceAtItsRealEnd() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        controller.start()
        defer { controller.stop() }
        controller.start(quiet())
        clock.advance(2 * minute)
        controller.end()
        #expect(controller.history.sessions.count == 1)
        #expect(controller.history.sessions.first?.outcome == .endedEarly)
        let version = controller.historyVersion

        clock.advance(2)
        #expect(controller.undoEnd())
        #expect(controller.history.sessions.isEmpty, "the early end is taken out")
        #expect(controller.historyVersion > version)
        #expect(controller.engine.isRunning)
        let onDisk = FocusHistory(url: dir.appendingPathComponent("history.json"))
        #expect(onDisk.sessions.isEmpty, "and out of the file")

        clock.advance(23 * minute)
        controller.engine.tick()
        #expect(controller.history.sessions.count == 1, "recorded once")
        let entry = try #require(controller.history.sessions.first)
        #expect(entry.outcome == .completed)
        #expect(entry.focused == 25 * minute)
    }

    @Test func endingAgainAfterAnUndoRecordsOneEntry() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        controller.start()
        defer { controller.stop() }
        controller.start(quiet())
        clock.advance(2 * minute)
        controller.end()
        controller.undoEnd()
        clock.advance(minute)
        controller.end()
        #expect(controller.history.sessions.count == 1)
        #expect(controller.history.sessions.first?.focused == 3 * minute)
    }

    @Test func aTooShortSessionHadNoEntryAndUndoIsStillFine() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        controller.start()
        defer { controller.stop() }
        controller.start(quiet())
        clock.advance(20)
        controller.end()
        #expect(controller.history.sessions.isEmpty)
        #expect(controller.undoEnd())
        #expect(controller.history.sessions.isEmpty)
        #expect(controller.engine.isRunning)
    }

    @Test func aRefusedUndoLeavesHistoryAlone() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        controller.start()
        defer { controller.stop() }
        controller.start(quiet())
        clock.advance(2 * minute)
        controller.end()
        clock.advance(6)
        #expect(!controller.undoEnd())
        #expect(controller.history.sessions.count == 1)
        #expect(controller.engine.session == nil)
    }

    @Test func undoRunsTheStartShortcutAgainButOpensNothing() async {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        let opener = FakeOpener()
        controller.opener = opener
        controller.start()
        defer { controller.stop() }
        var plan = quiet()
        plan.launchApps = ["com.example.editor"]
        plan.startShortcut = "Focus On"
        plan.endShortcut = "Focus Off"
        plan.resources = [WorkspaceResource(kind: .webPage, displayName: "example.com", url: "https://example.com/paper")]
        controller.start(plan)
        clock.advance(2 * minute)
        controller.end()
        controller.undoEnd()
        await controller.settleShortcuts()
        #expect(opener.shortcuts == ["Focus On", "Focus Off", "Focus On"], "Apple Focus goes back on")
        #expect(opener.apps.count == 1, "apps are not launched a second time")
        #expect(opener.opened.count == 1, "documents and pages opened at the start, and not again")
    }

    @Test func blockingAgainAfterUndoIsNotANewBlock() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        controller.blocksNothing = true
        controller.start()
        defer { controller.stop() }
        controller.start(SessionPlan(goal: "", duration: 25 * minute, mode: .block, apps: [], websites: ["youtube.com"]))
        controller.end()
        #expect(!controller.quietsNextSweep)
        controller.undoEnd()
        #expect(controller.quietsNextSweep, "tabs put back at the end are blocked again quietly")
        controller.end()

        // Nothing to sweep: nothing armed to silence a later session.
        controller.start(SessionPlan(goal: "", duration: 25 * minute, mode: .block, apps: [], websites: []))
        controller.end()
        controller.undoEnd()
        #expect(!controller.quietsNextSweep)
    }

    @Test func theEventIsTheModelsCueToRepublish() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        var seen: [SessionEvent] = []
        controller.onSessionEvent = { seen.append($0) }
        controller.start()
        defer { controller.stop() }
        controller.start(quiet())
        controller.end()
        controller.undoEnd()
        #expect(seen.last == .undone, "the model publishes focus.json and Plaque's file on every event")
        // And what it would publish says focusing, not idle.
        let file = FocusFile.snapshot(session: controller.engine.session)
        #expect(file.focusing && file.until != nil)
    }
}

@MainActor
struct UndoEndModelTests {
    private func setUp() -> (NidusModel, FocusController, TestClock, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-undo-model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        controller.onSessionEvent = { [weak model] event in model?.sessionDidChange(event) }
        controller.start()
        return (model, controller, clock, dir)
    }

    private func quiet() -> SessionPlan {
        SessionPlan(goal: "Write the report", duration: 25 * minute, mode: .block, apps: [], websites: [])
    }

    @Test func theEndedCardOffersUndoAndUndoRestoresTheSession() {
        let (model, controller, clock, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(quiet())
        clock.advance(2 * minute)
        model.endSession()
        #expect(model.cards.undoOffered)
        #expect(model.pendingFinish != nil, "the question was asked about the recorded entry")

        clock.advance(2)
        #expect(model.undoEnd())
        #expect(!model.cards.undoOffered)
        #expect(model.pendingFinish == nil, "its entry is gone, so is its question")
        #expect(model.isActive && !model.isPaused)
        #expect(controller.history.sessions.isEmpty)
        #expect(model.cards.nextStep == nil)
    }

    @Test func undoIsNotOfferedAfterACompletedOrStrictEnd() {
        let (model, controller, clock, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(quiet())
        clock.advance(25 * minute)
        controller.engine.tick()
        #expect(!model.cards.undoOffered)

        var strict = quiet()
        strict.strict = true
        controller.start(strict)
        clock.advance(2 * minute)
        controller.end()
        #expect(!model.cards.undoOffered)
        #expect(!model.undoEnd())
    }

    @Test func aRefusedUndoWithdrawsTheOffer() {
        let (model, controller, clock, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(quiet())
        clock.advance(2 * minute)
        model.endSession()
        clock.advance(6)
        #expect(!model.undoEnd())
        #expect(!model.cards.undoOffered)
        #expect(!model.isActive)
    }

    @Test func aNextStepWrittenBeforeUndoIsNotKept() throws {
        let (model, controller, clock, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        let notes = ResumeNoteStore(url: dir.appendingPathComponent(ResumeNoteStore.fileName))
        model.resumeNotes = notes
        controller.start(quiet())
        clock.advance(2 * minute)
        model.endSession()
        // The card makes this (it needs a host); the model's own undo clears it.
        let step = NextStepSession(seed: .init(goal: "Write the report", entryID: controller.history.sessions.last?.id),
                                   historyIsOff: false, store: notes)
        model.cards.nextStep = step
        step.setText("Run the figures")
        #expect(step.isSaved && notes.notes.count == 1)
        clock.advance(1)
        #expect(model.undoEnd())
        #expect(notes.notes.isEmpty, "the session did not end, so it leaves no note")
        #expect(model.cards.nextStep == nil)
    }
}

// MARK: - Forgotten pause

@MainActor
struct ForgottenPauseTests {
    private func lingering(_ events: EventLog) -> Int { events.all.filter { $0 == .pauseLingering }.count }

    @Test func aPauseTheUserChoseIsRemindedOnceAfterTenMinutes() {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.pause()
        h.clock.advance(10 * minute - 1)
        h.engine.tick()
        #expect(lingering(h.events) == 0)
        h.clock.advance(1)
        h.engine.tick()
        #expect(lingering(h.events) == 1)
        h.clock.advance(30 * minute)
        h.engine.tick()
        h.engine.tick()
        #expect(lingering(h.events) == 1, "once per pause")
        #expect(h.engine.isPaused, "nothing resumes or ends it by itself")
        #expect(h.engine.remaining == 60 * minute)
    }

    @Test func sleepAndLockAreNotForgottenPauses() {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.systemWillSleep()
        h.clock.advance(3 * 60 * minute)
        h.engine.tick()
        #expect(lingering(h.events) == 0)
    }

    @Test func eachPauseGetsItsOwnReminder() {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.pause()
        h.clock.advance(10 * minute)
        h.engine.tick()
        h.engine.resume()
        h.clock.advance(minute)
        h.engine.pause()
        h.clock.advance(9 * minute)
        h.engine.tick()
        #expect(lingering(h.events) == 1, "the new pause has not lasted ten minutes")
        h.clock.advance(minute)
        h.engine.tick()
        #expect(lingering(h.events) == 2)
    }

    @Test func aShortPauseResumedInTimeIsNeverReminded() {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.pause()
        h.clock.advance(5 * minute)
        h.engine.tick()
        h.engine.resume()
        h.clock.advance(30 * minute)
        h.engine.tick()
        #expect(lingering(h.events) == 0)
    }

    @Test func itWaitsWhileAwayAndComesWhenTheyAreBack() {
        let h = Harness()
        var away = true
        h.engine.isAway = { away }
        h.engine.start(qlPlan(60))
        h.engine.pause()
        h.clock.advance(15 * minute)
        h.engine.tick()
        #expect(lingering(h.events) == 0, "not behind a lock screen")
        away = false
        h.engine.tick()
        #expect(lingering(h.events) == 1)
    }

    @Test func aRelaunchKeepsWhenTheyPausedAndWhetherTheyWereTold() {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.pause()
        h.clock.advance(11 * minute)
        let (second, secondEvents) = h.relaunch()
        second.tick()
        #expect(lingering(secondEvents) == 1, "paused eleven minutes ago, told now")
        let (third, thirdEvents) = h.relaunch()
        third.tick()
        #expect(lingering(thirdEvents) == 0, "told already for this pause")
    }

    @Test func aPauseSavedWithoutAStartTimeCountsFromTheRelaunch() throws {
        let h = Harness()
        h.engine.start(qlPlan(60))
        h.engine.pause()
        var record = try #require(h.store.record)
        record.session?.pausedAt = nil
        h.store.save(record)
        h.clock.advance(20 * minute)
        let (second, events) = h.relaunch()
        second.tick()
        #expect(lingering(events) == 0)
        h.clock.advance(10 * minute)
        second.tick()
        #expect(lingering(events) == 1)
    }

    @Test func theReminderFieldsDecodeTolerantly() throws {
        let h = Harness()
        h.engine.start(qlPlan(60))
        let data = try JSONEncoder().encode(try #require(h.engine.session))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pausedAt"] = "yesterday"
        object["pauseReminded"] = "yes"
        let bad = try JSONDecoder().decode(SessionState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(bad.pausedAt == nil && !bad.pauseReminded && bad.plan == qlPlan(60), "the session survives")
        object.removeValue(forKey: "pausedAt")
        object.removeValue(forKey: "pauseReminded")
        let old = try JSONDecoder().decode(SessionState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.pausedAt == nil && !old.pauseReminded)
    }

    @Test func theControllerHoldsTheReminderWhileTheScreenIsLocked() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-pause-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        var count = 0
        controller.onSessionEvent = { if $0 == .pauseLingering { count += 1 } }
        controller.start()
        defer { controller.stop() }
        controller.start(SessionPlan(goal: "", duration: 60 * minute, mode: .block, apps: [], websites: []))
        controller.pause()
        clock.advance(12 * minute)
        controller.screenDidLock()
        controller.engine.tick()
        #expect(count == 0)
        controller.screenDidUnlock()
        controller.engine.tick()
        #expect(count == 1)
        #expect(controller.engine.isPaused)
    }
}

// MARK: - +5, +15, +30

@MainActor
struct AddTimeVariantsTests {
    private func setUp() -> (NidusModel, FocusController, TestClock, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-addtime-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clock = TestClock()
        let controller = FocusController(directory: dir, now: { clock.now })
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        controller.start()
        return (model, controller, clock, dir)
    }

    @Test func optionHeldMeansFifteenAndTheMenuOffersFiveFifteenThirty() {
        #expect(NidusModel.addTimeMinutes(optionHeld: false) == 5)
        #expect(NidusModel.addTimeMinutes(optionHeld: true) == 15)
        #expect(NidusModel.addTimeSteps == [5, 15, 30])
    }

    @Test func eachStepMovesTheEndByThatMuch() {
        let (model, controller, _, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(SessionPlan(goal: "", duration: 25 * minute, mode: .block, apps: [], websites: []))
        model.addTime()
        #expect(model.remaining == 30 * minute, "the +5 button")
        model.addTime(minutes: NidusModel.addTimeMinutes(optionHeld: true))
        #expect(model.remaining == 45 * minute)
        model.addTime(minutes: 30)
        #expect(model.remaining == 75 * minute)
        #expect(controller.engine.session?.budget == 75 * minute, "the planned total follows")
    }

    @Test func theTwentyFourHourLimitHoldsForEveryStep() {
        let (model, controller, _, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(SessionPlan(goal: "", duration: 24 * 60 * minute - 10 * minute, mode: .block, apps: [], websites: []))
        model.addTime(minutes: 30)
        #expect(model.remaining == SessionPlan.maximumDuration, "only the 10 minutes that fit were added")
        model.addTime(minutes: 15)
        model.addTime()
        #expect(model.remaining == SessionPlan.maximumDuration)
    }

    @Test func aPausedSessionTakesTheTimeToo() {
        let (model, controller, _, dir) = setUp()
        defer { controller.stop(); try? FileManager.default.removeItem(at: dir) }
        controller.start(SessionPlan(goal: "", duration: 25 * minute, mode: .block, apps: [], websites: []))
        controller.pause()
        model.addTime(minutes: 15)
        #expect(model.remaining == 40 * minute && model.isPaused)
    }
}
