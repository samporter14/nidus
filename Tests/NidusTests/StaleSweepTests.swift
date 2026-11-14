//
//  StaleSweepTests.swift
//  NidusTests
//
//  A browser sweep runs off the main actor. One sent under session A's rules
//  may come back after A has ended and B has begun; its redirects belong to
//  A, so they are not counted in B, shown as a card, or allowed to use up
//  the quiet flag meant for the sweep after them.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct StaleSweepTests {
    /// A sweep that holds until released, and records what it was asked.
    private final class HeldSweep: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var calls: [String] = []
        private var holdsNext = true

        var goals: [String] { lock.withLock { calls } }

        func run(goal: String) -> [String] {
            let holds = lock.withLock { () -> Bool in
                calls.append(goal)
                defer { holdsNext = false }
                return holdsNext
            }
            guard holds else { return [] }
            gate.wait()
            return ["example.com"]
        }

        func release() { gate.signal() }
    }

    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-stale-sweep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plan(_ goal: String) -> SessionPlan {
        SessionPlan(goal: goal, duration: 25 * 60, mode: .block, apps: [], websites: ["example.com"])
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aSweepFromAnEndedSessionIsNotCountedInTheNext() async {
        let held = HeldSweep()
        let controller = FocusController(directory: folder())
        controller.sweepWork = { _, goal, _, _ in (held.run(goal: goal), [:]) }
        var shown: [BlockedItem] = []
        controller.onBlocked = { shown.append($0) }
        controller.start()
        defer { controller.stop() }

        controller.start(plan("A"))
        await settle { held.goals == ["A"] }
        controller.end()
        controller.start(plan("B"))
        held.release()
        // The stale result comes back, and B's rules get a sweep of their own.
        await settle { held.goals.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(held.goals.first == "A")
        #expect(held.goals.dropFirst().allSatisfy { $0 == "B" }, "later sweeps are judged by B's rules")
        #expect(controller.engine.session?.plan.goal == "B")
        #expect(controller.engine.session?.blocks.isEmpty == true, "A's redirect is not B's block")
        #expect(shown.isEmpty, "no card for a block from a session that has ended")
    }

    @Test func aStaleSweepDoesNotUseUpTheQuietFlag() async {
        let held = HeldSweep()
        let controller = FocusController(directory: folder())
        controller.sweepWork = { _, goal, _, _ in (held.run(goal: goal), [:]) }
        controller.start()
        defer { controller.stop() }

        controller.start(plan("A"))
        await settle { held.goals == ["A"] }
        // Ending and undoing puts tabs back and arms the quiet flag for the
        // sweep that blocks them again.
        controller.end()
        #expect(controller.engine.undoEnd())
        #expect(controller.quietsNextSweep)
        let generation = controller.sweepGeneration
        held.release()
        await settle { held.goals.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))
        // The held sweep was stale and left the flag alone; the fresh sweep
        // that followed is the one that used it.
        #expect(controller.sweepGeneration == generation)
        #expect(!controller.quietsNextSweep)
        #expect(controller.engine.session?.blocks.isEmpty == true)
    }

    @Test func aCurrentSweepIsReported() async {
        let controller = FocusController(directory: folder())
        controller.sweepWork = { _, _, _, _ in (["example.com"], [:]) }
        var shown: [BlockedItem] = []
        controller.onBlocked = { shown.append($0) }
        controller.start()
        defer { controller.stop() }
        controller.start(plan("A"))
        await settle { !shown.isEmpty }
        #expect(controller.engine.session?.blocks["example.com"] == 1)
        #expect(shown.count == 1)
    }

    @Test func onlyTheSameGenerationIsCurrent() {
        #expect(FocusController.sweepIsCurrent(asked: 3, now: 3))
        #expect(!FocusController.sweepIsCurrent(asked: 2, now: 3))
    }
}
