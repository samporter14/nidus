//
//  SessionResolution.swift
//  Nidus
//
//  How a `SessionRequest` becomes the `SessionPlan` a session commits to:
//  what the request names, over what Settings and the popover say. This is
//  the one resolution. `NidusModel.startSession` uses it for every start,
//  and a sequence uses it for each of its work blocks when it starts, so a
//  block is exactly the session the same request would have been.
//
//  Pure: everything it reads from the model comes in as `StartDefaults`, so
//  it is tested without a model, a window or a session. docs/design-0.4.md,
//  "A plan is the snapshot".
//

import Foundation

/// What a request leaves unsaid is taken from here.
struct StartDefaults {
    var mode: SessionPlan.Mode
    var selectedCategoryIDs: [String]
    var categories: [FocusCategory]
    var reopensQuitApps = false
    var launchApps: [String] = []
    var startShortcut: String?
    var endShortcut: String?
    var strict = false
    /// Settings' rules for a break; nil is the unrestricted break.
    var defaultBreakRules: BreakRules?
    /// The name a plan keeps for a project, nil for one that no longer exists.
    var projectName: (UUID) -> String? = { _ in nil }
}

/// A plan, and whether its end is a meeting's start (so no break follows).
struct ResolvedSession {
    var plan: SessionPlan
    var endsAtMeeting: Bool
}

extension SessionRequest {
    /// The plan this request starts, or nil when it would block nothing (a
    /// block list session whose categories are all empty). `length` is asked
    /// only when the request names none, and only once the request is known
    /// to start: it may read the calendar, which is used up when it does.
    func resolved(with defaults: StartDefaults, length: () -> (minutes: Int, fromMeeting: Bool)) -> ResolvedSession? {
        let mode = self.mode ?? defaults.mode
        let ids = categoryIDs ?? defaults.selectedCategoryIDs
        let chosen = defaults.categories.filter { ids.contains($0.id) }
        guard mode == .allow || !chosen.allSatisfy(\.isEmpty) else { return nil }
        // A length the request didn't give: the next meeting if it was chosen
        // (read again now, in case it moved), else an "until" time, else the
        // popover's length.
        let minutes: Int
        let fromMeeting: Bool
        if let own = self.minutes {
            (minutes, fromMeeting) = (own, false)
        } else {
            (minutes, fromMeeting) = length()
        }
        var plan = SessionPlan(
            goal: (goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            duration: minutes > 0 ? TimeInterval(minutes * 60) : nil,
            mode: mode,
            categories: chosen,
            reopensQuitApps: defaults.reopensQuitApps,
            launchApps: launchApps ?? defaults.launchApps,
            startShortcut: startShortcut.map { $0.isEmpty ? nil : $0 } ?? defaults.startShortcut,
            endShortcut: endShortcut.map { $0.isEmpty ? nil : $0 } ?? defaults.endShortcut
        )
        plan.strict = strict ?? defaults.strict
        plan.setupID = setupID
        plan.projectID = projectID
        plan.projectName = projectID.flatMap(defaults.projectName)
        // A request's own break, else Settings' (`breakLength` nil), as before.
        plan.breakLength = breakMinutes.map { TimeInterval(max(0, $0) * 60) }
        plan.breakRules = breakRules ?? defaults.defaultBreakRules
        plan.websiteExceptions = mode == .block ? Self.exceptions(of: chosen, adding: websiteExceptions) : []
        plan.resources = resources
        plan.sequenceStep = sequenceStep
        return ResolvedSession(plan: plan, endsAtMeeting: fromMeeting)
    }

    /// The exceptions of the chosen categories, then the request's own, each
    /// once.
    static func exceptions(of categories: [FocusCategory], adding extra: [WebsiteException]) -> [WebsiteException] {
        var all: [WebsiteException] = []
        for exception in categories.flatMap(\.websiteExceptions) + extra where !all.contains(exception) {
            all.append(exception)
        }
        return all
    }
}
