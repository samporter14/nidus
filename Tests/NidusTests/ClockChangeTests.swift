//
//  ClockChangeTests.swift
//  NidusTests
//
//  The countdown follows the monotonic clock, not the wall clock: setting the
//  Mac's date moves neither the time left nor a snooze nor a break.
//

import Foundation
import Testing
@testable import Nidus

/// A wall clock and a monotonic clock the test moves apart or together.
@MainActor
final class TwoClocks {
    var wall = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var mono: TimeInterval = 5_000
    /// Time passing: both clocks move.
    func advance(_ seconds: TimeInterval) { wall += seconds; mono += seconds }
    /// Someone sets the date: only the wall clock moves.
    func setClock(by seconds: TimeInterval) { wall += seconds }
}

@MainActor
struct ClockChangeTests {
    let clocks = TwoClocks()
    let store = MemoryStore()
    let engine: SessionEngine
    let events: EventLog

    init() {
        let clocks = clocks
        engine = SessionEngine(store: store, now: { clocks.wall }, monotonic: { clocks.mono })
        let events = EventLog()
        engine.onEvent = { events.all.append($0) }
        self.events = events
    }

    private var savedDeadline: Date? {
        if case .running(let deadline)? = store.record?.session?.phase { return deadline }
        return nil
    }

    @Test func aForwardJumpDoesNotEndTheSession() {
        engine.start(plan(25))
        clocks.advance(10 * minute)
        clocks.setClock(by: 3600)
        engine.tick()
        #expect(engine.session != nil)
        #expect(engine.remaining == 15 * minute)
    }

    @Test func aBackwardJumpDoesNotLengthenTheSession() {
        engine.start(plan(25))
        clocks.advance(10 * minute)
        clocks.setClock(by: -3600)
        #expect(engine.remaining == 15 * minute)
        clocks.advance(15 * minute)
        engine.tick()
        #expect(engine.session == nil)
        if case .ended(.completed, _)? = events.last {} else { Issue.record("expected a completed end") }
    }

    @Test func normalTimeStillCountsDownAndCompletes() {
        engine.start(plan(25))
        clocks.advance(24 * minute)
        engine.tick()
        #expect(engine.remaining == 1 * minute)
        clocks.advance(minute)
        engine.tick()
        #expect(engine.session == nil)
    }

    @Test func afterTheNotificationTheSavedDeadlineFollowsTheNewWallClock() throws {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        clocks.setClock(by: 3600)
        engine.systemClockDidChange()
        #expect(engine.remaining == 20 * minute)
        #expect(savedDeadline == clocks.wall.addingTimeInterval(20 * minute))
        // And it carries on from there.
        clocks.advance(20 * minute)
        engine.tick()
        #expect(engine.session == nil)
    }

    @Test func aBackwardJumpIsRebasedToo() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        clocks.setClock(by: -7200)
        engine.systemClockDidChange()
        #expect(engine.remaining == 20 * minute)
        #expect(savedDeadline == clocks.wall.addingTimeInterval(20 * minute))
    }

    @Test func aRelaunchAfterTheNotificationIsRight() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        clocks.setClock(by: 3600)
        engine.systemClockDidChange()
        let relaunched = SessionEngine(store: store, now: { clocks.wall }, monotonic: { clocks.mono })
        relaunched.restore()
        #expect(relaunched.remaining == 20 * minute)
    }

    @Test func aSnoozeSurvivesAForwardJump() {
        engine.start(plan(25))
        engine.snooze("com.tinyspeck.slackmacgap", for: 3 * minute)
        clocks.advance(minute)
        clocks.setClock(by: 3600)
        engine.systemClockDidChange()
        engine.tick()
        #expect(engine.session?.snoozes["com.tinyspeck.slackmacgap"] != nil)
        #expect(engine.snoozesEnding(within: 3 * minute).first?.end == clocks.wall.addingTimeInterval(2 * minute))
        clocks.advance(2 * minute)
        engine.tick()
        #expect(engine.session?.snoozes.isEmpty == true)
    }

    @Test func aSnoozeDoesNotOutliveItsTimeOnABackwardJump() {
        engine.start(plan(25))
        engine.snooze("com.tinyspeck.slackmacgap", for: 3 * minute)
        clocks.setClock(by: -3600)
        clocks.advance(3 * minute)
        engine.tick()
        #expect(engine.session?.snoozes.isEmpty == true)
    }

    @Test func aBreaksEndIsRebased() {
        engine.breakLength = 5 * minute
        engine.start(plan(25))
        clocks.advance(25 * minute)
        engine.tick()
        #expect(engine.isOnBreak)
        clocks.advance(2 * minute)
        clocks.setClock(by: 3600)
        #expect(engine.breakRemaining == 3 * minute)
        engine.systemClockDidChange()
        #expect(engine.breakRemaining == 3 * minute)
        #expect(store.record?.pendingBreak?.endsAt == clocks.wall.addingTimeInterval(3 * minute))
        engine.tick()
        #expect(engine.isOnBreak)
        clocks.advance(3 * minute)
        engine.tick()
        #expect(engine.session != nil)
    }

    @Test func pauseAndResumeAcrossAJumpKeepTimeRight() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        engine.pause()
        clocks.advance(2 * minute)
        clocks.setClock(by: 3600)
        engine.systemClockDidChange()
        #expect(engine.remaining == 20 * minute)
        engine.resume()
        #expect(engine.remaining == 20 * minute)
        #expect(savedDeadline == clocks.wall.addingTimeInterval(20 * minute))
        clocks.advance(20 * minute)
        engine.tick()
        #expect(engine.session == nil)
    }

    @Test func aJumpWhileRunningThenPauseCapturesTheRightRemaining() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        clocks.setClock(by: -3600)
        engine.pause()
        #expect(engine.remaining == 20 * minute)
    }

    @Test func extendingAfterAJumpIsStillRight() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        clocks.setClock(by: 3600)
        engine.systemClockDidChange()
        engine.extend(by: 10 * minute)
        #expect(engine.remaining == 30 * minute)
    }

    @Test func aNotificationWithNoJumpChangesNothing() {
        engine.start(plan(25))
        clocks.advance(5 * minute)
        engine.systemClockDidChange()
        #expect(engine.remaining == 20 * minute)
        #expect(savedDeadline == clocks.wall.addingTimeInterval(20 * minute))
    }

    @Test func theNotificationWhileIdleIsHarmless() {
        engine.systemClockDidChange()
        #expect(engine.session == nil)
        #expect(store.record == nil)
    }
}
