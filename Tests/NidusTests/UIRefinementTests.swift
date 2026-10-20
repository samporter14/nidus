import Testing
@testable import Nidus

@MainActor
struct RecentGoalHistoryTests {
    let goals = ["Revise Figure 3", "Update Specific Aims"]

    @Test func browsingReturnsToTheUnfinishedDraft() {
        var history = RecentGoalHistory()
        let draft = "Finish the results paragraph"
        let newest = history.move(1, current: draft, goals: goals)
        #expect(newest == goals[0])
        let oldest = history.move(1, current: newest!, goals: goals)
        #expect(oldest == goals[1])
        let newer = history.move(-1, current: oldest!, goals: goals)
        #expect(newer == goals[0])
        #expect(history.move(-1, current: newer!, goals: goals) == draft)
    }

    @Test func editingARecalledGoalBecomesTheNewDraft() {
        var history = RecentGoalHistory()
        _ = history.move(1, current: "Original draft", goals: goals)
        let edited = "Revise Figure 3 legend"
        #expect(history.move(1, current: edited, goals: goals) == goals[0])
        #expect(history.move(-1, current: goals[0], goals: goals) == edited)
    }

    @Test func menuSelectionPreservesTheDraftAndHistoryPosition() {
        var history = RecentGoalHistory()
        history.select(goals[1], from: goals, current: "New goal ✨")
        #expect(history.move(-1, current: goals[1], goals: goals) == goals[0])
        #expect(history.move(-1, current: goals[0], goals: goals) == "New goal ✨")
    }

    @Test func emptyHistoryDoesNotConsumeAnArrowOrChangeTheDraft() {
        var history = RecentGoalHistory()
        #expect(history.move(1, current: "Draft", goals: []) == nil)
    }
}

@MainActor
struct SetupOverflowLayoutTests {
    @Test(arguments: [0, 1, 2, 3, 4, 7])
    func narrowerCandidatesPreserveEverySetupAndOrder(_ count: Int) {
        let setups = (0..<count).map { FocusSetup(name: "A complete setup name \($0)") }
        for cap in 0...4 {
            let parts = FocusSetupsBar.split(setups, inlineCount: cap)
            #expect(parts.inline.count <= cap)
            #expect(parts.inline + parts.overflow == setups)
            #expect(parts.overflow.first == setups.dropFirst(parts.inline.count).first)
        }
    }

    @Test func allSetupsRemainReachableWhenNoChipFits() {
        let setups = [FocusSetup(name: "A name too wide for the entire popover")]
        let parts = FocusSetupsBar.split(setups, inlineCount: 0)
        #expect(parts.inline.isEmpty)
        #expect(parts.overflow == setups)
        #expect(FocusSetupsBar.shortcutNumber(for: setups[0], in: setups, problem: { _ in nil }) == 1)
    }
}
