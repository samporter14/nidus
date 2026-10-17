//
//  FocusProjects.swift
//  Nidus
//
//  The model's side of projects (FocusProject.swift): the saved list, and
//  the lookups the start path uses. docs/design-0.4.md, "Projects".
//

import Foundation

extension NidusModel.Key {
    static let projects = "projects"
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
        project(id)?.displayName
    }
}
