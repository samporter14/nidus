// A setup prepared for this one session. Its request is a value snapshot:
// changing the composer never edits the saved setup or Settings.
import SwiftUI

struct SetupComposerDraft: Equatable, Sendable {
    let source: FocusSetup
    let name: String
    let previousGoal: String
    let usesSavedGoal: Bool
    var request: SessionRequest

    init(setup: FocusSetup, categories: [FocusCategory], goal: String, project: UUID?,
         projects: [FocusProject], previousGoal: String? = nil) {
        source = setup
        name = setup.displayName
        self.previousGoal = previousGoal ?? goal
        usesSavedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        request = setup.startRequest(categories: categories, goalDraft: goal,
                                     popoverProject: project, projects: projects)
    }

    /// Edits only the visible goal and length, retaining every workspace,
    /// break, strictness, project and exception override in the snapshot.
    func composing(goal: String, minutes: Int?, fixedEnd: Bool) -> SessionRequest {
        var edited = request
        edited.goal = goal
        edited.minutes = minutes
        edited.hasFixedEnd = fixedEnd
        return edited
    }
}

extension NidusModel {
    var composerMinutes: Int {
        get { setupDraft?.request.minutes ?? durationMinutes }
        set {
            if setupDraft != nil { setupDraft?.request.minutes = newValue; untilTarget = nil }
            else { durationMinutes = newValue }
        }
    }

    var composerCategoryIDs: [String] {
        get { setupDraft?.request.categoryIDs ?? selectedCategoryIDs }
        set {
            if setupDraft != nil { setupDraft?.request.categoryIDs = newValue }
            else { selectedCategoryIDs = newValue }
            startProblem = nil
        }
    }

    var composerCategories: [FocusCategory] { categories.filter { composerCategoryIDs.contains($0.id) } }
    var composerMode: SessionPlan.Mode { setupDraft?.request.mode ?? mode }
    var composerStrict: Bool { setupDraft?.request.strict ?? strictMode }
    var composerBreakMinutes: Int { setupDraft?.request.breakMinutes ?? breakMinutes }
    var composerSelectionSummary: String {
        let names = composerCategories.map(\.name)
        return names.isEmpty ? "Nothing" : names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) categories"
    }

    var composerProjectID: UUID? {
        get {
            if let draft = setupDraft { return FocusProject.choosable(draft.request.projectID, in: projects) }
            return selectedProjectID
        }
        set {
            if setupDraft != nil { setupDraft?.request.projectID = newValue }
            else { selectedProjectID = newValue }
            selectedResumeNoteID = nil
        }
    }

    func isComposerCategorySelected(_ category: FocusCategory) -> Bool { composerCategoryIDs.contains(category.id) }
    func toggleComposerCategory(_ category: FocusCategory) {
        var ids = composerCategoryIDs
        if let index = ids.firstIndex(of: category.id) { ids.remove(at: index) } else { ids.append(category.id) }
        composerCategoryIDs = ids
    }

    @discardableResult
    func prepareSetup(_ setup: FocusSetup) -> Bool {
        guard canStartNew else { return false }
        // A goal supplied by the previous setup is not a new typed override.
        // Switching setups should show the next one's goal; actual edits stay.
        let goal: String
        if let previous = setupDraft, previous.usesSavedGoal, goalDraft == (previous.request.goal ?? "") {
            goal = previous.previousGoal
        } else {
            goal = goalDraft
        }
        let draft = SetupComposerDraft(setup: setup, categories: categories, goal: goal,
                                       project: composerProjectID, projects: projects,
                                       previousGoal: setupDraft?.previousGoal)
        setupDraft = draft
        goalDraft = draft.request.goal ?? ""
        untilTarget = nil
        meetings.isChosen = false
        customLengthDraft = nil
        startProblem = nil
        composerFocusRequest += 1
        showPopover()
        return true
    }

    func discardSetupDraft() {
        guard let draft = setupDraft else { return }
        goalDraft = draft.previousGoal
        setupDraft = nil
        untilTarget = nil
        meetings.isChosen = false
        customLengthDraft = nil
        startProblem = nil
        composerFocusRequest += 1
    }

    func makeComposerRequest(now: Date) -> SessionRequest {
        let clause = GoalLengthClause.split(goalDraft, now: now)
        let goal = clause?.goal ?? goalDraft
        guard let draft = setupDraft else {
            return SessionRequest(goal: goal, minutes: clause?.minutes(now: now), projectID: selectedProjectID)
        }
        let hasEndTime = pendingUntil(now: now) != nil
        let minutes = clause?.minutes(now: now)
            ?? (endsAtNextMeeting ? nil : FocusLength.startMinutes(durationMinutes: composerMinutes, until: untilTarget, now: now))
        let fixed: Bool
        if case .until? = clause?.length { fixed = true } else { fixed = clause == nil && hasEndTime }
        var request = draft.composing(goal: goal, minutes: minutes, fixedEnd: fixed)
        request.projectID = composerProjectID
        return request
    }

    /// A prepared setup's fallback length belongs to its own request only;
    /// unrelated links, schedules and resume actions keep their usual defaults.
    func fallbackMinutes(for request: SessionRequest, now: Date = Date()) -> Int {
        if let draft = setupDraft, request.setupID == draft.request.setupID {
            return FocusLength.startMinutes(durationMinutes: composerMinutes, until: untilTarget, now: now)
        }
        return minutesForNextStart(now: now)
    }
}

/// Appears only while a saved setup is being adjusted for one session.
struct SetupDraftRow: View {
    @ObservedObject var model: NidusModel
    var body: some View {
        if let draft = model.setupDraft {
            HStack(spacing: NidusSpacing.sm) {
                Label("\(draft.name) · just this time", systemImage: "slider.horizontal.3")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Cancel", action: model.discardSetupDraft)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel changes for this session")
            }
            .font(.system(size: 12))
            .foregroundStyle(Solanum.clayText)
            .help("Your saved setup stays unchanged. Adjust this session's goal, length, categories or project in the composer.")
        }
    }
}
