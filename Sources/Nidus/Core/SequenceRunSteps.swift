//
//  SequenceRunSteps.swift
//  Nidus
//
//  Reading a running sequence: which step comes next, and where it stands.
//  The engine moves a run on with these; the popover and cards word them
//  (App/FocusSequences.swift). docs/design-0.4.md, "Sequences".
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

extension SequenceRun {
    /// The work block that follows the step in progress, with the break
    /// before it when there is one.
    struct Block: Equatable, Sendable {
        var index: Int
        var plan: SessionPlan
        var rest: Rest?
    }

    /// A break between two blocks.
    struct Rest: Equatable, Sendable {
        var index: Int
        var length: TimeInterval
        var rules: BreakRules?
    }

    func step(at index: Int) -> SequenceStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// What follows the step in progress: the next work block, behind a break
    /// if one comes first. Several breaks in a row are the first one (the
    /// editor does not allow them). A break at the end has no block after it
    /// and is not taken: nil, the run is over. A break of no length is skipped.
    func nextBlock() -> Block? {
        var i = index + 1
        var rest: Rest?
        if case .rest(let length, let rules)? = step(at: i) {
            if length > 0 { rest = Rest(index: i, length: length, rules: rules) }
            while case .rest? = step(at: i) { i += 1 }
        }
        guard case .work(let plan)? = step(at: i) else { return nil }
        return Block(index: i, plan: plan, rest: rest)
    }

    /// The work block after the step in progress, whatever breaks sit before it.
    func nextWork() -> (index: Int, plan: SessionPlan)? {
        var i = index + 1
        while case .rest? = step(at: i) { i += 1 }
        guard case .work(let plan)? = step(at: i) else { return nil }
        return (i, plan)
    }

    /// How many work blocks the run has.
    var workCount: Int { steps.filter(\.isWork).count }

    /// The work block in progress, counted from 1. On a break it is the one
    /// just done.
    var blockNumber: Int { blockNumber(at: index) }

    /// The work block at `index`, counted from 1.
    func blockNumber(at index: Int) -> Int {
        guard !steps.isEmpty else { return 0 }
        return steps[...min(max(index, 0), steps.count - 1)].filter(\.isWork).count
    }

    /// The step in progress is a break.
    var isOnRest: Bool {
        if case .rest? = current { return true }
        return false
    }
}
