//
//  GoalRecallTests.swift
//  NidusTests
//
//  ↑ and ↓ in the goal field: the typed draft survives a trip through the
//  recent goals, and ↓ with nothing recalled is left alone.
//

import Foundation
import Testing
@testable import Nidus

struct GoalRecallTests {
    private let goals = ["write report", "review PR", "plan week"]

    @Test func upRecallsAndDownRestoresTheTypedDraft() {
        var recall = GoalRecall()
        #expect(recall.step(1, draft: "abc", goals: goals) == "write report")
        #expect(recall.step(-1, draft: "write report", goals: goals) == "abc")
        #expect(recall.index == nil)
        #expect(recall.stashed == nil)
    }

    @Test func downAloneLeavesTheDraftAlone() {
        var recall = GoalRecall()
        #expect(recall.step(-1, draft: "abc", goals: goals) == nil)
    }

    @Test func upPastTheEndStaysOnTheLastGoal() {
        var recall = GoalRecall()
        _ = recall.step(1, draft: "", goals: goals)
        _ = recall.step(1, draft: goals[0], goals: goals)
        #expect(recall.step(1, draft: goals[1], goals: goals) == "plan week")
        #expect(recall.step(1, draft: goals[2], goals: goals) == "plan week")
        #expect(recall.index == 2)
        // An empty draft is stashed too and comes back.
        _ = recall.step(-1, draft: goals[2], goals: goals)
        _ = recall.step(-1, draft: goals[1], goals: goals)
        #expect(recall.step(-1, draft: goals[0], goals: goals) == "")
    }

    @Test func editingARecalledGoalEndsTheRecall() {
        var recall = GoalRecall()
        _ = recall.step(1, draft: "abc", goals: goals)
        recall.draftChanged(to: "write report v2", goals: goals)
        #expect(recall.index == nil)
        #expect(recall.step(-1, draft: "write report v2", goals: goals) == nil)
    }

    @Test func noGoalsIsIgnored() {
        var recall = GoalRecall()
        #expect(recall.step(1, draft: "abc", goals: []) == nil)
        #expect(recall.step(-1, draft: "abc", goals: []) == nil)
    }
}
