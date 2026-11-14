//
//  GoalRecall.swift
//  Nidus
//
//  Where ↑ and ↓ are in the recent goals while the goal field is focused.
//

import Foundation

/// ↑ and ↓ in the goal field: ↑ steps back through the recent goals and ↓
/// forward again, ending on whatever was typed before the first ↑.
struct GoalRecall: Equatable {
    /// The recent goal on show; nil when the field is as typed.
    private(set) var index: Int?
    /// What the field held before the first ↑, put back when ↓ steps past
    /// the newest goal.
    private(set) var stashed: String?

    /// Steps through `goals` (+1 is ↑, older; -1 is ↓, newer). Returns the
    /// draft to show, or nil when the key should be left alone: no goals,
    /// or ↓ with no recall under way.
    mutating func step(_ step: Int, draft: String, goals: [String]) -> String? {
        draftChanged(to: draft, goals: goals)
        guard !goals.isEmpty else { return nil }
        guard let current = index else {
            guard step > 0 else { return nil }
            stashed = draft
            index = 0
            return goals[0]
        }
        let next = current + step
        if next < 0 {
            let restored = stashed ?? ""
            index = nil
            stashed = nil
            return restored
        }
        // Past the oldest goal it stays where it is.
        index = min(next, goals.count - 1)
        return goals[index!]
    }

    /// The field changed. Anything other than the recalled goal itself is
    /// an edit or a clear, so the recall starts over.
    mutating func draftChanged(to draft: String, goals: [String]) {
        guard let current = index else { return }
        if current >= goals.count || goals[current] != draft {
            index = nil
            stashed = nil
        }
    }
}
