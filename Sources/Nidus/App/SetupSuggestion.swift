//
//  SetupSuggestion.swift
//  Nidus
//
//  "Save this as a setup": a quiet line in the idle popover for someone who
//  keeps starting the same plan by hand. The same plan is the same length,
//  categories and mode, started from the popover three times in two weeks,
//  with no setup saved yet. It is offered once for a plan: dismissing it, or
//  using it, ends the offer for that plan for good.
//
//  What was started is kept as plan fingerprints (no goals, no times beyond
//  the day), and only while sessions are recorded. Clear History clears
//  them. Nothing starts, saves or changes by itself: the line opens the
//  existing add-setup page, as the plus button does.
//

import Foundation

/// A plan without its goal: what makes two starts the same.
struct PlanSignature: Codable, Hashable, Sendable {
    /// 0 is open-ended.
    var minutes: Int
    /// Category ids, sorted.
    var categoryIDs: [String]
    /// `SessionPlan.Mode.rawValue`.
    var mode: String

    init(minutes: Int, categoryIDs: [String], mode: SessionPlan.Mode) {
        self.minutes = minutes
        self.categoryIDs = categoryIDs.sorted()
        self.mode = mode.rawValue
    }
}

/// One start of a plan.
struct PlanStart: Codable, Equatable, Sendable {
    var plan: PlanSignature
    var at: Date
}

enum SetupSuggestion {
    /// Starts of one plan that make it a habit.
    static let startsNeeded = 3
    /// "Recently": the last two weeks.
    static let window: TimeInterval = 14 * 24 * 60 * 60
    /// Starts kept at all; more than enough to count three.
    static let keepLast = 20

    /// `starts` with one more, older ones forgotten.
    static func recording(_ plan: PlanSignature, at date: Date, in starts: [PlanStart]) -> [PlanStart] {
        let recent = starts.filter { date.timeIntervalSince($0.at) <= window }
        return Array((recent + [PlanStart(plan: plan, at: date)]).suffix(keepLast))
    }

    /// Whether to offer saving `current` (the plan the popover would start
    /// now). Only the plan in hand is offered, since saving opens a setup of
    /// exactly the popover's choices.
    static func shouldOffer(current: PlanSignature?, starts: [PlanStart], dismissed: [PlanSignature],
                            hasSetups: Bool, now: Date) -> Bool {
        guard !hasSetups, let current, !dismissed.contains(current) else { return false }
        let count = starts.filter { $0.plan == current && now.timeIntervalSince($0.at) <= window }.count
        return count >= startsNeeded
    }
}

// MARK: - The model's side

extension NidusModel.Key {
    static let planStarts = "planStarts"
    static let dismissedPlanSuggestions = "dismissedPlanSuggestions"
}

extension NidusModel {
    private var planStarts: [PlanStart] {
        get { preferenceList(Key.planStarts) }
        set { setPreference(newValue, Key.planStarts) }
    }

    private var dismissedPlanSuggestions: [PlanSignature] {
        get { preferenceList(Key.dismissedPlanSuggestions) }
        set { setPreference(newValue, Key.dismissedPlanSuggestions) }
    }

    /// The plan a Start with the popover's choices would make, or nil when
    /// its length is a one-off (an "until" time, the next meeting) that a
    /// saved setup could not keep.
    func currentPlanSignature(now: Date = Date()) -> PlanSignature? {
        guard pendingUntil(now: now) == nil, !endsAtNextMeeting else { return nil }
        return PlanSignature(minutes: durationMinutes, categoryIDs: selectedCategories.map(\.id), mode: mode)
    }

    /// Remembers that a session of this plan was started from the popover.
    /// Only while sessions are recorded.
    func notePlanStarted(_ plan: PlanSignature, now: Date = Date()) {
        guard recordsHistory else { return }
        planStarts = SetupSuggestion.recording(plan, at: now, in: planStarts)
    }

    /// Whether the idle popover offers "Save this as a setup".
    func offersSetupSuggestion(now: Date = Date()) -> Bool {
        recordsHistory && SetupSuggestion.shouldOffer(current: currentPlanSignature(now: now), starts: planStarts,
                                                      dismissed: dismissedPlanSuggestions, hasSetups: !setups.isEmpty,
                                                      now: now)
    }

    /// "Not now", for good: this plan is not offered again.
    func dismissSetupSuggestion() {
        guard let current = currentPlanSignature(), !dismissedPlanSuggestions.contains(current) else { return }
        dismissedPlanSuggestions.append(current)
    }

    /// Opens the add-setup page, as the plus button does, and counts the
    /// offer as answered.
    func acceptSetupSuggestion() {
        dismissSetupSuggestion()
        addSetupFromCurrentChoices()
    }

    /// What Clear History forgets: the starts the suggestion counts. Plans
    /// already dismissed stay dismissed.
    func clearPlanStarts() {
        planStarts = []
    }
}
