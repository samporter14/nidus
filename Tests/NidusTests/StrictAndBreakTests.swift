//
//  StrictAndBreakTests.swift
//  NidusTests
//
//  1.3: strict sessions (no snooze, no pause; the widget gates ending early)
//  and breaks between sessions.
//

import Foundation
import Testing
@testable import Nidus

func strictPlan(_ minutes: Double? = 25) -> SessionPlan {
    var p = plan(minutes)
    p.strict = true
    return p
}

@MainActor
struct StrictTests {
    @Test func aStrictSessionCannotBePausedOrSnoozed() {
        let h = Harness()
        h.engine.start(strictPlan())
        h.engine.pause()
        #expect(h.engine.isRunning, "pausing would stop the blocking")
        h.engine.snooze("youtube.com")
        #expect(h.engine.session?.snoozes.isEmpty == true)
        #expect(h.engine.enforcement?.websites.contains("youtube.com") == true)
    }

    @Test func itCanStillBeExtendedEndedAndSleep() {
        let h = Harness()
        h.engine.start(strictPlan())
        h.engine.extend(by: 5 * minute)
        #expect(h.engine.remaining == 30 * minute)

        h.engine.systemWillSleep()
        #expect(h.engine.isPaused, "a sleeping Mac is not focusing, strict or not")
        h.engine.systemDidWake()
        #expect(h.engine.isRunning)

        h.engine.end()
        #expect(h.engine.session == nil)
    }

    @Test func strictIsKeptWithTheSessionAndOldPlansAreNotStrict() throws {
        let h = Harness()
        h.engine.start(strictPlan())
        let (engine, _) = h.relaunch()
        #expect(engine.session?.plan.strict == true)

        let old = #"{"goal":"x","duration":1500,"mode":"block","apps":[],"websites":[]}"#
        let decoded = try JSONDecoder().decode(SessionPlan.self, from: Data(old.utf8))
        #expect(decoded.strict == false)
    }
}

@MainActor
struct BreakTests {
    func harness(breakMinutes: Double = 5) -> Harness {
        let h = Harness()
        h.engine.breakLength = breakMinutes * minute
        return h
    }

    @Test func aCompletedSessionStartsABreakWithNothingBlocked() {
        let h = harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(h.engine.session == nil)
        #expect(h.engine.isOnBreak)
        #expect(h.engine.enforcement == nil, "nothing is blocked on a break")
        #expect(h.engine.breakRemaining == 5 * minute)
        guard case .ended(.completed, _) = h.events.last else { Issue.record("no ended event"); return }
    }

    @Test func endingEarlyOrOpenEndedEarnsNoBreak() {
        let h = harness()
        h.engine.start(plan(25))
        h.engine.end()
        #expect(!h.engine.isOnBreak)

        h.engine.start(plan(nil))
        h.clock.advance(SessionPlan.maximumDuration)
        h.engine.tick()
        #expect(!h.engine.isOnBreak, "an open-ended session has no planned end to rest after")
    }

    @Test func noBreakLengthMeansNoBreak() {
        let h = harness(breakMinutes: 0)
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
    }

    @Test func whenTheBreakEndsTheSamePlanStartsAgain() {
        let h = harness()
        var p = plan(25)
        p.goal = "Chapter three"
        h.engine.start(p)
        h.clock.advance(25 * minute)
        h.engine.tick()
        h.clock.advance(4 * minute + 50)
        #expect(h.engine.breakEnding(within: 15) != nil)
        #expect(h.engine.breakEnding(within: 5) == nil)
        h.clock.advance(10)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
        #expect(h.engine.session?.plan.goal == "Chapter three")
        #expect(h.engine.remaining == 25 * minute)
        #expect(h.events.last == .started)
    }

    @Test func aBreakThatRanOutLongAgoIsDropped() {
        let h = harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        // The lid was closed through the end of the break and long after.
        h.clock.advance(2 * 60 * minute)
        h.engine.tick()
        #expect(!h.engine.isOnBreak)
        #expect(h.engine.session == nil, "no session starts for someone who may not be there")
        #expect(h.events.last == .breakEnded)
    }

    @Test func skipEndAndStartingByHand() {
        let h = harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        h.engine.skipBreak()
        #expect(h.engine.isRunning && !h.engine.isOnBreak)

        h.clock.advance(25 * minute)
        h.engine.tick()
        h.engine.endBreak()
        #expect(!h.engine.isOnBreak && h.engine.session == nil)
        #expect(h.events.last == .breakEnded)

        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        var other = plan(45)
        other.goal = "Something else"
        h.engine.start(other)
        #expect(!h.engine.isOnBreak, "starting a session by hand ends the break")
        #expect(h.engine.remaining == 45 * minute)
    }

    @Test func aBreakSurvivesARelaunch() {
        let h = harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        h.clock.advance(minute)
        let (engine, _) = h.relaunch()
        #expect(engine.isOnBreak)
        #expect(engine.breakRemaining == 4 * minute)
    }
}
