//
//  ReEnforcementTests.swift
//  NidusTests
//
//  The periodic sweep that asks stubborn blocked apps to quit again, and the
//  bound on how long quitting waits for browsers. Real processes can't be
//  faked, so these hold the decisions: the per-app sweep step, the cadence,
//  and the tabs-restored marker rule.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct ReEnforcementTests {
    private typealias Step = AppBlocker.SweepStep

    private func step(_ id: String = "com.example.app", terminated: Bool = false, hidden: Bool = false,
                      openAtStart: Bool = false, mode: AppBlocker.Mode, action: AppBlocker.Action) -> Step {
        AppBlocker.sweepStep(bundleID: id, isTerminated: terminated, isHidden: hidden,
                             wasOpenAtStart: openAtStart, mode: mode, action: action)
    }

    @Test func aBlockedAppIsAskedToQuitAgain() {
        #expect(step(mode: .block(["com.example.app"]), action: .terminate) == .askToQuit)
        // Hidden or not makes no difference to a quit.
        #expect(step(hidden: true, mode: .block(["com.example.app"]), action: .terminate) == .askToQuit)
    }

    @Test func anAppThatIsNotBlockedIsLeftAlone() {
        #expect(step(mode: .block(["com.other"]), action: .terminate) == .nothing)
        #expect(step(mode: .allow(["com.example.app"]), action: .terminate) == .nothing)
    }

    @Test func aTerminatedAppIsLeftAlone() {
        #expect(step(terminated: true, mode: .block(["com.example.app"]), action: .terminate) == .nothing)
        #expect(step(terminated: true, mode: .block(["com.example.app"]), action: .hide) == .nothing)
    }

    @Test func hideActionRehidesOnlyWhatIsShowing() {
        #expect(step(mode: .block(["com.example.app"]), action: .hide) == .hide)
        #expect(step(hidden: true, mode: .block(["com.example.app"]), action: .hide) == .nothing)
    }

    @Test func allowModeOnlyHidesWhatWasOpenAtStart() {
        #expect(step(openAtStart: true, mode: .allow([]), action: .terminate) == .hide)
        #expect(step(hidden: true, openAtStart: true, mode: .allow([]), action: .terminate) == .nothing)
        #expect(step(openAtStart: false, mode: .allow([]), action: .terminate) == .askToQuit)
        // Block mode ignores the open-at-start set.
        #expect(step(openAtStart: true, mode: .block(["com.example.app"]), action: .terminate) == .askToQuit)
    }

    @Test func exemptAppsAndNidusAreNeverTouched() {
        for id in AppBlocker.exempt {
            #expect(step(id, mode: .allow([]), action: .terminate) == .nothing)
            #expect(step(id, mode: .block([id]), action: .hide) == .nothing)
        }
        if let own = Bundle.main.bundleIdentifier {
            #expect(step(own, mode: .allow([]), action: .terminate) == .nothing)
        }
    }

    @Test func theSweepIsDueEveryFifthTickOnlyWhileEnforcing() {
        let every = FocusController.sweepEvery
        let due = (0...(every * 3)).filter { FocusController.sweepIsDue(tick: $0, enforcing: true) }
        #expect(due == [every, every * 2, every * 3])
        #expect(!(0...(every * 3)).contains { FocusController.sweepIsDue(tick: $0, enforcing: false) })
    }

    @Test func refusedAppsStartEmptyAndClearOnStop() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-reenf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        #expect(controller.refusedApps.isEmpty)
        controller.start()
        controller.start(SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: []))
        controller.stop()
        #expect(controller.refusedApps.isEmpty)
    }

    @Test func quitRestoreIsBoundedAtAboutThreeSeconds() {
        #expect(FocusController.quitRestoreTimeout == 3)
    }

    @Test func aTimedOutRestoreStillMarksWhenBlockingWillResume() {
        let mark = FocusController.marksTabsRestored(restored:timedOut:hasSession:isOnBreak:)
        #expect(mark(0, true, true, false))
        #expect(mark(0, true, false, true))
        #expect(!mark(0, true, false, false))
        #expect(mark(2, false, true, false))
        #expect(!mark(0, false, true, true))
        #expect(!mark(2, false, false, false))
        // The three-argument form is the not-timed-out case.
        #expect(FocusController.marksTabsRestored(restored: 1, hasSession: true, isOnBreak: false))
        #expect(!FocusController.marksTabsRestored(restored: 0, hasSession: true, isOnBreak: false))
    }
}
