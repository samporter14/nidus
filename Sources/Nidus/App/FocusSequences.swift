//
//  FocusSequences.swift
//  Nidus
//
//  Sequences: a run of different work blocks and breaks, saved once and
//  started in one click. "40 min writing, 10 min break, 25 min figures". A
//  saved sequence (`FocusSequence`) is only a definition; starting it
//  resolves every step into a `SequenceRun` snapshot (each work block a full
//  `SessionPlan`, built by the same resolution as any other start), and the
//  engine runs that. Editing the saved sequence, a setup or Settings
//  afterwards changes nothing about a run under way.
//
//  The definition, its checks, its summary and its resolution are pure
//  functions of the sequence and the live setups and categories, so they are
//  tested without a model. The model's side (the list, starting one, the
//  popover's line, the right-click menu) is below. The editor is
//  FocusSequencesPage.swift. docs/design-0.4.md, "Sequences".
//

import AppKit
import Foundation
import SwiftUI

extension NidusModel.Key {
    static let sequences = "sequences"
}

// MARK: - The definition

struct FocusSequence: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var steps: [Step]

    static let defaultName = "New sequence"
    static let nameLimit = 60
    /// More than this is a day's plan, not a run; the editor stops adding.
    static let stepLimit = 20
    /// A work block is finite: at least a minute, at most the cap on any session.
    static let workMinutes = 1...Int(SessionPlan.maximumDuration / 60)
    static let breakMinutes = 1...180
    /// What the pickers offer; a saved length that is not among them is listed too.
    static let workChoices = [10, 15, 20, 25, 30, 40, 45, 50, 60, 75, 90, 120]
    static let breakChoices = [2, 5, 10, 15, 20, 30]

    init(id: UUID = UUID(), name: String = FocusSequence.defaultName, steps: [Step] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// A first draft that passes its own checks: a block, a break, a block.
    static func starter() -> FocusSequence {
        FocusSequence(steps: [.work(minutes: 40), .rest(minutes: 10), .work(minutes: 25)])
    }

    /// Only the id and name must be there. Steps decode one by one, so a step
    /// a later version wrote differently is dropped, not the sequence or the
    /// list it is in.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        steps = c.decodeLossy([Step].self, forKey: .steps)
    }

    enum CodingKeys: String, CodingKey { case id, name, steps }

    /// The name as shown: never empty, never longer than a row can hold.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled sequence" : String(trimmed.prefix(Self.nameLimit))
    }

    // MARK: Steps

    struct Step: Codable, Identifiable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case work, rest }

        /// What stays blocked during a break step: the next work block's
        /// setup says (or Settings' default rules), nothing, or its own.
        enum BreakChoice: Codable, Equatable, Sendable {
            case inherit
            case none
            case own(BreakRules)

            private enum CodingKeys: String, CodingKey { case mode, rules }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                switch c.decodeTolerant(String.self, forKey: .mode) {
                case "none": self = .none
                case "own": self = .own(c.decodeTolerant(BreakRules.self, forKey: .rules) ?? BreakRules())
                default: self = .inherit
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .inherit: try c.encode("inherit", forKey: .mode)
                case .none: try c.encode("none", forKey: .mode)
                case .own(let rules):
                    try c.encode("own", forKey: .mode)
                    try c.encode(rules, forKey: .rules)
                }
            }
        }

        var id: UUID
        var kind: Kind
        /// Minutes. A work block of 0 would be open-ended, which a sequence
        /// can't be (it must end to go on), so it is not valid.
        var minutes: Int
        /// Work: the setup it takes its blocking, strictness and the rest from.
        var setupID: UUID?
        /// Work: the goal; empty takes the setup's own, else none.
        var goal: String
        /// Work: the project it counts toward.
        var projectID: UUID?
        /// Break only.
        var rules: BreakChoice

        static func work(minutes: Int = 25, goal: String = "", setupID: UUID? = nil, projectID: UUID? = nil) -> Step {
            Step(id: UUID(), kind: .work, minutes: minutes, setupID: setupID, goal: goal, projectID: projectID, rules: .inherit)
        }

        static func rest(minutes: Int = 10, rules: BreakChoice = .inherit) -> Step {
            Step(id: UUID(), kind: .rest, minutes: minutes, setupID: nil, goal: "", projectID: nil, rules: rules)
        }

        var isWork: Bool { kind == .work }

        init(id: UUID, kind: Kind, minutes: Int, setupID: UUID?, goal: String, projectID: UUID?, rules: BreakChoice) {
            self.id = id
            self.kind = kind
            self.minutes = minutes
            self.setupID = setupID
            self.goal = goal
            self.projectID = projectID
            self.rules = rules
        }

        /// The id and kind must be there; every other field falls back alone.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            minutes = c.decodeTolerant(Int.self, forKey: .minutes) ?? (kind == .work ? 25 : 10)
            setupID = c.decodeTolerant(UUID.self, forKey: .setupID)
            goal = c.decodeTolerant(String.self, forKey: .goal) ?? ""
            projectID = c.decodeTolerant(UUID.self, forKey: .projectID)
            rules = c.decodeTolerant(BreakChoice.self, forKey: .rules) ?? .inherit
        }

        enum CodingKeys: String, CodingKey { case id, kind, minutes, setupID, goal, projectID, rules }
    }

    // MARK: Order

    /// `steps` with the step `step` places later (earlier when negative),
    /// stopping at either end. Unchanged when the id isn't in it.
    static func moving(_ id: Step.ID, by step: Int, in steps: [Step]) -> [Step] {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return steps }
        let target = min(max(index + step, 0), steps.count - 1)
        guard target != index else { return steps }
        var moved = steps
        moved.insert(moved.remove(at: index), at: target)
        return moved
    }

    // MARK: Whether it can start

    /// What the checks need to know about the world: the same things a start
    /// reads. Steps with no setup take the popover's mode and categories.
    struct Context: Sendable {
        var setups: [FocusSetup]
        var categories: [FocusCategory]
        var mode: SessionPlan.Mode
        var selectedCategoryIDs: [String]
    }

    enum Problem: Equatable, Sendable {
        case noWorkBlock
        case startsWithBreak
        case endsWithBreak
        /// The 1-based number of the second of two breaks in a row.
        case breaksInARow(step: Int)
        case lengthOutOfRange(step: Int)
        /// The step's setup has been deleted.
        case setupGone(step: Int)
        /// The step's setup can't start (its categories are gone, or empty).
        case setupCannotStart(step: Int, reason: String)
        /// No setup, and the popover's own choice would block nothing.
        case nothingToBlock(step: Int)

        var message: String {
            switch self {
            case .noWorkBlock: return "Add at least one work block."
            case .startsWithBreak: return "A sequence can\u{2019}t start with a break. Put a work block first."
            case .endsWithBreak: return "A sequence can\u{2019}t end with a break. Put a work block last, or remove the break."
            case .breaksInARow(let step): return "Step \(step) is a second break in a row. Make it one longer break."
            case .lengthOutOfRange(let step): return "Step \(step) needs a length of at least a minute."
            case .setupGone(let step): return "Step \(step)\u{2019}s setup was deleted. Choose another or none."
            case .setupCannotStart(let step, let reason): return "Step \(step): \(reason)."
            case .nothingToBlock(let step): return "Step \(step) would block nothing. Choose a setup, or pick a category to block in the popover."
            }
        }
    }

    /// Everything wrong with it, in step order. Empty: it can start.
    func problems(in context: Context) -> [Problem] {
        var found: [Problem] = []
        if !steps.contains(where: \.isWork) { found.append(.noWorkBlock) }
        if steps.first?.kind == .rest { found.append(.startsWithBreak) }
        if steps.count > 1, steps.last?.kind == .rest { found.append(.endsWithBreak) }
        for (index, step) in steps.enumerated() {
            let number = index + 1
            if index > 0, step.kind == .rest, steps[index - 1].kind == .rest { found.append(.breaksInARow(step: number)) }
            let range = step.isWork ? Self.workMinutes : Self.breakMinutes
            if !range.contains(step.minutes) { found.append(.lengthOutOfRange(step: number)) }
            guard step.isWork else { continue }
            if let id = step.setupID {
                if let setup = context.setups.first(where: { $0.id == id }) {
                    if let problem = setup.problem(in: context.categories) {
                        found.append(.setupCannotStart(step: number, reason: problem.reason))
                    }
                } else {
                    found.append(.setupGone(step: number))
                }
            } else if context.mode == .block {
                let chosen = context.categories.filter { context.selectedCategoryIDs.contains($0.id) }
                if chosen.allSatisfy(\.isEmpty) { found.append(.nothingToBlock(step: number)) }
            }
        }
        return found
    }

    // MARK: Saying what it is

    /// How a work step is named in a summary: its goal, else its setup's
    /// name, else just "focus".
    func label(of step: Step, setups: [FocusSetup]) -> String {
        let goal = step.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { return goal }
        if let id = step.setupID, let setup = setups.first(where: { $0.id == id }) { return setup.displayName }
        return "focus"
    }

    /// "40 min writing \u{2192} 10 min break \u{2192} 25 min figures".
    func summary(setups: [FocusSetup]) -> String {
        steps.map { step in
            let length = Self.lengthText(step.minutes)
            return step.isWork ? "\(length) \(label(of: step, setups: setups))" : "\(length) break"
        }.joined(separator: " \u{2192} ")
    }

    /// "25 min". A length of nothing is not "open-ended" here, since a
    /// sequence has none of those: the plan says what is wrong, plainly.
    static func lengthText(_ minutes: Int) -> String {
        minutes > 0 ? FocusFormat.duration(minutes: minutes) : "0 min"
    }

    var workBlockCount: Int { steps.filter(\.isWork).count }

    /// Minutes of work and of rest, for "3 blocks \u{00B7} 1 hr 15 min of work".
    var workMinutes: Int { steps.filter(\.isWork).reduce(0) { $0 + $1.minutes } }
    var totalMinutes: Int { steps.reduce(0) { $0 + $1.minutes } }

    /// "3 blocks \u{00B7} 1 hr 15 min work \u{00B7} 1 hr 25 min in all".
    func totals() -> String {
        let blocks = workBlockCount
        var parts = ["\(blocks) \(blocks == 1 ? "block" : "blocks")", "\(Self.lengthText(workMinutes)) of work"]
        if totalMinutes != workMinutes { parts.append("\(Self.lengthText(totalMinutes)) in all") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Starting

    /// The request a work step starts: its setup's (blocking, strictness, the
    /// rest, through `FocusSetup.request`), the step's goal and length over
    /// it, and its project when that project still exists. A project that was
    /// deleted starts the block with none, as a setup's does.
    ///
    /// A setup that follows the popover's project takes `popoverProject`, its
    /// saved choice, as it does wherever it starts; a step's own project
    /// comes after and wins.
    func request(for step: Step, setups: [FocusSetup], categories: [FocusCategory],
                 popoverProject: UUID? = nil, projectExists: (UUID) -> Bool) -> SessionRequest {
        var request: SessionRequest
        if let id = step.setupID, let setup = setups.first(where: { $0.id == id }) {
            request = setup.request(categories: categories, goalDraft: step.goal, popoverProject: popoverProject)
            request.setupID = request.setupID ?? setup.id
        } else {
            let goal = step.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            request = SessionRequest(goal: goal.isEmpty ? nil : goal)
        }
        request.minutes = step.minutes
        // Nothing here was clicked: a block that starts by itself must not
        // raise macOS's prompt. The sequence's own start asked once.
        request.asksBrowserAccess = false
        if let project = step.projectID, projectExists(project) {
            request.projectID = project
        } else if let inherited = request.projectID, !projectExists(inherited) {
            request.projectID = nil
        }
        return request
    }

    /// The run to start: every step resolved now. `plan` turns a work step's
    /// request into its plan (the model's `resolveSession`), or nil when it
    /// can't start, in which case nothing does. A break's rules are resolved
    /// here too: its own, none, or those of the next block's plan.
    func resolved(startedAt: Date, id: UUID = UUID(), request: (Step) -> SessionRequest,
                  plan: (SessionRequest) -> SessionPlan?) -> SequenceRun? {
        var plans: [Int: SessionPlan] = [:]
        for (index, step) in steps.enumerated() where step.isWork {
            guard let resolved = plan(request(step)) else { return nil }
            plans[index] = resolved
        }
        var resolvedSteps: [SequenceStep] = []
        for (index, step) in steps.enumerated() {
            if step.isWork, let plan = plans[index] {
                resolvedSteps.append(.work(plan))
                continue
            }
            let rules: BreakRules?
            switch step.rules {
            case .inherit:
                let next = plans.filter { $0.key > index }.min { $0.key < $1.key }
                rules = next?.value.breakRules
            case .none:
                rules = nil
            case .own(let own):
                rules = own
            }
            resolvedSteps.append(.rest(length: TimeInterval(step.minutes * 60), rules: rules))
        }
        var run = SequenceRun(id: id, sequenceID: self.id, name: displayName, steps: resolvedSteps, startedAt: startedAt)
        for index in run.steps.indices {
            if case .work(var plan) = run.steps[index] {
                plan.sequenceStep = run.ref(at: index)
                run.steps[index] = .work(plan)
            }
        }
        return run
    }
}

// MARK: - Saying where a run is

extension SequenceRun {
    /// How a plan reads as the next thing: "25 min Figures".
    static func describe(_ plan: SessionPlan) -> String {
        let goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = Int(((plan.duration ?? 0) / 60).rounded())
        return "\(FocusFormat.duration(minutes: minutes)) \(goal.isEmpty ? "block" : goal)"
    }

    /// "10 min break".
    static func describe(rest length: TimeInterval) -> String {
        "\(FocusFormat.duration(minutes: Int((length / 60).rounded()))) break"
    }

    /// What comes after the step in progress, as a short phrase.
    var upNext: String {
        guard let next = nextBlock() else { return "last block" }
        return next.rest.map { Self.describe(rest: $0.length) } ?? Self.describe(next.plan)
    }

    /// The popover's one line. While a block runs: "Block 2 of 3 \u{00B7} next:
    /// 10 min break". On a break: "Next: 25 min Figures".
    var progressLine: String {
        if isOnRest {
            guard let next = nextWork() else { return "Last break" }
            return "Next: \(Self.describe(next.plan))"
        }
        return "Block \(blockNumber) of \(workCount) \u{00B7} next: \(upNext)"
    }
}

// MARK: - The model's side

extension NidusModel {
    /// The saved sequences, in the order they show. None to begin with.
    var sequences: [FocusSequence] {
        get { preferenceList(Key.sequences) }
        set { setPreference(newValue, Key.sequences) }
    }

    var sequenceContext: FocusSequence.Context {
        FocusSequence.Context(setups: setups, categories: categories, mode: mode, selectedCategoryIDs: selectedCategoryIDs)
    }

    /// Why a saved sequence can't start now, or nil.
    func problem(of sequence: FocusSequence) -> FocusSequence.Problem? {
        sequence.problems(in: sequenceContext).first
    }

    /// The run being walked: a block running or paused, or a break between
    /// two blocks. nil outside a sequence.
    var runningSequence: SequenceRun? {
        guard let engine, engine.isInSequence else { return nil }
        return engine.sequence
    }

    /// The popover's line while a sequence runs; nil otherwise.
    var sequenceLine: String? { runningSequence?.progressLine }

    /// Starts a saved sequence: every step resolved now into a snapshot, then
    /// the first block through the same guard as `startSession`. False,
    /// starting nothing, while a session or break is on, when the sequence has
    /// a problem, or when a block would block nothing.
    @discardableResult
    func startSequence(_ sequence: FocusSequence) -> Bool {
        guard let controller, canStartNew else { return false }
        guard sequence.problems(in: sequenceContext).isEmpty else { return false }
        let setups = self.setups, categories = self.categories
        guard let run = sequence.resolved(
            startedAt: Date(),
            request: {
                sequence.request(for: $0, setups: setups, categories: categories, popoverProject: self.selectedProjectID,
                                 projectExists: { self.project($0) != nil })
            },
            plan: { self.resolveSession($0)?.plan }
        ), controller.startSequence(run) else { return false }
        if case .work(let first)? = run.steps.first { rememberGoal(first.goal) }
        host?.feedback.play(.success)
        askBrowsersNeedingConsent()
        return true
    }

    func updateSequence(_ id: FocusSequence.ID, _ change: (inout FocusSequence) -> Void) {
        var all = sequences
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        guard all[index] != sequences[index] else { return }
        sequences = all
    }

    func deleteSequence(_ id: FocusSequence.ID) {
        sequences.removeAll { $0.id == id }
        host?.workspace.goBackInSettings()
    }

    func moveSequence(_ id: FocusSequence.ID, by step: Int) {
        var all = sequences
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + step, 0), all.count - 1)
        guard target != index else { return }
        all.insert(all.remove(at: index), at: target)
        sequences = all
    }

    /// A new sequence, with a block, a break and a block to start from, last
    /// in the list, and its page open.
    @discardableResult
    func addSequence() -> FocusSequence {
        let sequence = FocusSequence.starter()
        sequences.append(sequence)
        openSequencePage(sequence)
        return sequence
    }

    // MARK: Pages

    nonisolated static let sequencePagePrefix = "sequence:"

    func openSequencePage(_ sequence: FocusSequence) {
        menuBarItem?.closePopover()
        host?.workspace.openSettingsPage(Self.sequencePagePrefix + sequence.id.uuidString, title: sequence.displayName)
    }

    /// One sequence's page at `sequence:<id>`; nil for one that was deleted.
    func makeSequencePage(id: String) -> AnyView? {
        guard id.hasPrefix(Self.sequencePagePrefix),
              let sequenceID = UUID(uuidString: String(id.dropFirst(Self.sequencePagePrefix.count))),
              sequences.contains(where: { $0.id == sequenceID }) else { return nil }
        return AnyView(FocusSequencePage(model: self, sequenceID: sequenceID))
    }

    // MARK: The menu bar's menu

    /// The sequences' items for the right-click menu, after the setups'.
    func sequenceMenuItems() -> [NSMenuItem] {
        FocusSequencesMenu.items(for: sequences, context: sequenceContext, setups: setups,
                                 target: self, action: #selector(startSequenceFromMenu(_:)))
    }

    @objc func startSequenceFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let sequence = sequences.first(where: { $0.id == id }) else { return }
        startSequence(sequence)
    }
}

/// The right-click menu's sequence items, built apart from the model so they
/// can be tested.
enum FocusSequencesMenu {
    /// Up to this many go straight in the menu; more go under "Start a sequence".
    static let inlineLimit = 3
    static let submenuTitle = "Start a sequence"
    static let symbol = "list.number"

    @MainActor
    static func items(for sequences: [FocusSequence], context: FocusSequence.Context, setups: [FocusSetup],
                      target: AnyObject?, action: Selector) -> [NSMenuItem] {
        guard !sequences.isEmpty else { return [] }
        let items = sequences.map { item(for: $0, context: context, setups: setups, target: target, action: action) }
        guard sequences.count > inlineLimit else { return items }
        let submenu = NSMenu(title: submenuTitle)
        items.forEach(submenu.addItem)
        let parent = NSMenuItem(title: submenuTitle, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        parent.submenu = submenu
        return [parent]
    }

    /// One that can't start has no action, so the menu leaves it dimmed.
    @MainActor
    private static func item(for sequence: FocusSequence, context: FocusSequence.Context, setups: [FocusSetup],
                             target: AnyObject?, action: Selector) -> NSMenuItem {
        let problem = sequence.problems(in: context).first
        let item = NSMenuItem(title: sequence.displayName, action: problem == nil ? action : nil, keyEquivalent: "")
        item.target = target
        item.representedObject = sequence.id.uuidString
        item.subtitle = problem.map { shortReason($0) } ?? sequence.summary(setups: setups)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// The menu has one line for it; the page has the whole sentence.
    static func shortReason(_ problem: FocusSequence.Problem) -> String {
        switch problem {
        case .setupGone, .setupCannotStart, .nothingToBlock: return "A block can\u{2019}t start"
        default: return "Needs fixing"
        }
    }
}
