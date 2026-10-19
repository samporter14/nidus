//
//  FocusProject.swift
//  Nidus
//
//  A project: a name that sessions, setups, sequences and resume notes can
//  point to by a stable id, so "Grant" is still the same project after it is
//  renamed "R01 renewal". Lightweight on purpose: no tasks, no due dates.
//
//  Shared by the app and its tests.
//

import Foundation

struct FocusProject: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Archived projects keep their history and notes but aren't offered for
    /// new sessions.
    var isArchived: Bool
    var createdAt: Date

    static let nameLimit = 60

    init(id: UUID = UUID(), name: String, isArchived: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    /// The name as shown: never empty, never longer than a row can hold.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled project" : String(trimmed.prefix(Self.nameLimit))
    }

    /// Only the id and name must be there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isArchived = c.decodeTolerant(Bool.self, forKey: .isArchived) ?? false
        createdAt = c.decodeTolerant(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    enum CodingKeys: String, CodingKey { case id, name, isArchived, createdAt }
}

// MARK: - Editing the list

/// The list of projects is edited by these pure functions, so what a rename,
/// an archive or a delete does is tested without a model. None of them
/// touches history: sessions, notes and setups point to a project by its id,
/// and an id never changes.
extension FocusProject {
    static let defaultName = "New project"

    /// What `adding` did.
    enum Addition: Equatable, Sendable {
        case added([FocusProject], FocusProject)
        /// The name was empty.
        case blank
        /// A project already has this name (compared without case or spaces
        /// at the ends); it is returned so the page can say which.
        case duplicate(FocusProject)
    }

    /// A name as typed, made fit to keep: spaces at the ends and line breaks
    /// gone, no longer than a row can hold.
    static func cleaned(_ raw: String) -> String {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
    }

    /// `name` added last. Ids are made here and kept for good.
    static func adding(_ name: String, to list: [FocusProject], id: UUID = UUID(), now: Date = Date()) -> Addition {
        let name = cleaned(name)
        guard !name.isEmpty else { return .blank }
        if let same = list.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }) {
            return .duplicate(same)
        }
        let project = FocusProject(id: id, name: name, createdAt: now)
        return .added(list + [project], project)
    }

    /// The project renamed. The text is kept as typed, up to the limit,
    /// because the page edits it live (trimming would eat the space between
    /// two words as it is typed); `displayName` trims. Same id, same date.
    static func renaming(_ id: UUID, to raw: String, in list: [FocusProject]) -> [FocusProject] {
        list.map { project in
            guard project.id == id else { return project }
            var renamed = project
            renamed.name = String(raw.components(separatedBy: .newlines).joined(separator: " ").prefix(nameLimit))
            return renamed
        }
    }

    static func settingArchived(_ id: UUID, to archived: Bool, in list: [FocusProject]) -> [FocusProject] {
        list.map { project in
            guard project.id == id else { return project }
            var changed = project
            changed.isArchived = archived
            return changed
        }
    }

    /// Only the project goes. Nothing that points to it is edited: history
    /// entries keep their id and the name they had, a note keeps its text.
    static func removing(_ id: UUID, from list: [FocusProject]) -> [FocusProject] {
        list.filter { $0.id != id }
    }

    /// Those offered for a new session: not archived.
    static func active(_ list: [FocusProject]) -> [FocusProject] {
        list.filter { !$0.isArchived }
    }

    /// The project a choice (the popover's, a setup's) still means: the id if
    /// it names a project that exists and isn't archived, else none. A
    /// deleted or archived project falls back to no project, quietly.
    static func choosable(_ id: UUID?, in list: [FocusProject]) -> UUID? {
        guard let id, let project = list.first(where: { $0.id == id }), !project.isArchived else { return nil }
        return id
    }

    /// What a session plan keeps for a project: its id and its name now. nil
    /// when the project doesn't exist, so a session never starts with an id
    /// that points nowhere. An archived project still resolves: finishing
    /// work on it (a resume note) is allowed, only offering it fresh isn't.
    static func planFields(for id: UUID?, in list: [FocusProject]) -> (id: UUID, name: String)? {
        guard let id, let project = list.first(where: { $0.id == id }) else { return nil }
        return (project.id, project.displayName)
    }
}

// MARK: - How history and notes name a project

/// A project as a past session or a note refers to it. A live project shows
/// its name now (so a rename shows everywhere it is read); one that has been
/// deleted shows the name it had when the record was made, and says so.
struct ProjectLabel: Equatable, Sendable {
    enum State: Equatable, Sendable { case live, archived, deleted }

    var name: String
    var state: State

    /// "R01 renewal", "R01 renewal (archived)", "Old pilot (deleted)".
    var text: String {
        switch state {
        case .live: name
        case .archived: "\(name) (archived)"
        case .deleted: name == Self.unnamed ? name : "\(name) (deleted)"
        }
    }

    /// What a deleted project is called when the record kept no name.
    static let unnamed = "A deleted project"

    /// nil for a record with no project at all. A stored id with no stored
    /// name and no live project is still a deleted project, called "A deleted project".
    static func of(id: UUID?, storedName: String?, in list: [FocusProject]) -> ProjectLabel? {
        if let id, let project = list.first(where: { $0.id == id }) {
            return ProjectLabel(name: project.displayName, state: project.isArchived ? .archived : .live)
        }
        let stored = storedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard id != nil || !stored.isEmpty else { return nil }
        return ProjectLabel(name: stored.isEmpty ? unnamed : String(stored.prefix(FocusProject.nameLimit)), state: .deleted)
    }
}
