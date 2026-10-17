//
//  FocusProjects.swift
//  Nidus
//
//  The model's side of projects (Core/FocusProject.swift): the saved list,
//  what the popover has chosen, the lookups the start path uses, and the
//  pages. docs/design-0.4.md, "Projects". The list is edited by the pure
//  functions in FocusProject.swift; nothing here touches history.
//

import SwiftUI

extension NidusModel.Key {
    static let projects = "projects"
    /// The project the popover's next Start counts toward.
    static let selectedProject = "selectedProject"
}

extension NidusModel {
    /// Every project, archived ones included, in the order they were made.
    var projects: [FocusProject] {
        get { preferenceList(Key.projects) }
        set { setPreference(newValue, Key.projects) }
    }

    func project(_ id: UUID?) -> FocusProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// The name a new session's plan keeps for its project. nil for a project
    /// that no longer exists: the session starts with no project rather than
    /// with a dangling one.
    func projectNameForPlan(_ id: UUID) -> String? {
        FocusProject.planFields(for: id, in: projects)?.name
    }

    // MARK: Editing

    @discardableResult
    func addProject(named name: String) -> FocusProject.Addition {
        let result = FocusProject.adding(name, to: projects)
        if case .added(let list, _) = result { projects = list }
        return result
    }

    func renameProject(_ id: UUID, to name: String) {
        projects = FocusProject.renaming(id, to: name, in: projects)
    }

    func setProjectArchived(_ id: UUID, _ archived: Bool) {
        projects = FocusProject.settingArchived(id, to: archived, in: projects)
    }

    /// Takes the project out of the list. History, notes and the sessions
    /// already recorded keep its id and the name they had.
    func deleteProject(_ id: UUID) {
        projects = FocusProject.removing(id, from: projects)
        host?.workspace.goBackInSettings()
    }

    // MARK: The popover's choice

    /// The project the next Start counts toward, or nil. Remembered between
    /// launches like the categories are: work on one project runs over days,
    /// and the choice is always on the popover's face. One that has been
    /// archived or deleted since reads as none.
    var selectedProjectID: UUID? {
        get {
            let saved: String = preference(Key.selectedProject, default: "")
            return FocusProject.choosable(UUID(uuidString: saved), in: projects)
        }
        set { setPreference(newValue?.uuidString ?? "", Key.selectedProject) }
    }

    /// The popover offers a picker only once there is a project to pick.
    var offersProjectPicker: Bool {
        FocusProjectPickerRow.isVisible(projects: projects)
    }

    /// An old plan (the last session, started again) with its project as it
    /// is now: renamed projects carry the new name; a deleted one is none.
    func withCurrentProject(_ plan: SessionPlan) -> SessionPlan {
        guard plan.projectID != nil else { return plan }
        var plan = plan
        let fields = FocusProject.planFields(for: plan.projectID, in: projects)
        plan.projectID = fields?.id
        plan.projectName = fields?.name
        return plan
    }

    // MARK: Starting

    /// "Start a session" on a project's page. Returns why it didn't start, or
    /// nil when it did. A session or break that is on is never replaced.
    @discardableResult
    func startSession(for project: FocusProject, goal: String) -> String? {
        switch ProjectStart.decide(project, goal: goal, isActive: isActive, isOnBreak: isOnBreak) {
        case .refused(let reason):
            return reason
        case .start(let request):
            return startSession(request) ? nil : "Nothing started. Pick a category with something to block."
        }
    }

    /// Why "Start a session" is unavailable on this project's page, or nil.
    func startRefusal(for project: FocusProject) -> String? {
        if case .refused(let reason) = ProjectStart.decide(project, goal: "", isActive: isActive, isOnBreak: isOnBreak) { return reason }
        return nil
    }

    // MARK: Numbers

    /// The sessions the numbers are worked out from. Read fresh each time a
    /// page draws, like the stats are.
    private var recordedSessions: [SessionEntry] { controller?.history.sessions ?? [] }

    func projectSummary(for id: UUID) -> ProjectSummary {
        ProjectSummary(projectID: id, sessions: recordedSessions)
    }

    var projectRoster: ProjectSummary.Roster {
        ProjectSummary.roster(projects: projects, sessions: recordedSessions)
    }

    // MARK: Pages

    nonisolated static let projectPagePrefix = "project:"

    /// One project's page, over the Stats tab (where the Projects list is).
    func openProjectPage(_ project: FocusProject) {
        menuBarItem?.closePopover()
        host?.workspace.openSettingsPage(Self.projectPagePrefix + project.id.uuidString, title: project.displayName)
    }

    /// The Projects list: a section of the Stats page.
    func openProjects() {
        menuBarItem?.closePopover()
        openSettings(.stats)
    }

    /// `project:<id>`; nil for a project that has been deleted.
    func makeProjectsPage(id: String) -> AnyView? {
        guard id.hasPrefix(Self.projectPagePrefix),
              let projectID = UUID(uuidString: String(id.dropFirst(Self.projectPagePrefix.count))),
              projects.contains(where: { $0.id == projectID }) else { return nil }
        return AnyView(FocusProjectPage(model: self, projectID: projectID))
    }
}
