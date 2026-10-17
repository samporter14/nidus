//
//  ResumeNote.swift
//  Nidus
//
//  A resume note: the next step you wrote down as a session ended, and
//  optionally a document, folder or web page to open with it. Kept after
//  unfinished sessions too, and offered in the popover until it is resumed or
//  dismissed. docs/design-0.4.md, "Resume notes".
//
//  These are the person's own words, not history: they are kept whether or
//  not sessions are recorded, and nothing here ever changes a session entry
//  or its "did you finish?" answer. The file and the model's side are
//  App/ResumeNotes.swift.
//

import Foundation

struct ResumeNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// The next step, at most `textLimit` characters. May be empty when the
    /// note is only a link.
    var text: String
    /// A document, folder or web page that opens when the note is resumed
    /// (and only then).
    var resource: WorkspaceResource?
    /// The goal of the session it was written after.
    var goal: String
    /// The project that session counted toward, and its name then.
    var projectID: UUID?
    var projectName: String?
    /// The history entry it was written after; nil when sessions aren't
    /// being recorded, or the session was too short to be.
    var entryID: UUID?
    var createdAt: Date
    var dismissedAt: Date?

    static let textLimit = 160

    init(id: UUID = UUID(), text: String, resource: WorkspaceResource? = nil, goal: String = "",
         projectID: UUID? = nil, projectName: String? = nil, entryID: UUID? = nil,
         createdAt: Date = Date(), dismissedAt: Date? = nil) {
        self.id = id
        self.text = Self.clean(text)
        self.resource = resource
        self.goal = goal
        self.projectID = projectID
        self.projectName = projectName
        self.entryID = entryID
        self.createdAt = createdAt
        self.dismissedAt = dismissedAt
    }

    /// Only the id must be there; a field that doesn't decode loses itself,
    /// never the note, and a note never takes the others in the file with it
    /// (see `ResumeNoteStore`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = Self.clean(c.decodeTolerant(String.self, forKey: .text) ?? "")
        resource = c.decodeTolerant(WorkspaceResource.self, forKey: .resource)
        goal = c.decodeTolerant(String.self, forKey: .goal) ?? ""
        projectID = c.decodeTolerant(UUID.self, forKey: .projectID)
        projectName = c.decodeTolerant(String.self, forKey: .projectName)
        entryID = c.decodeTolerant(UUID.self, forKey: .entryID)
        createdAt = c.decodeTolerant(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        dismissedAt = c.decodeTolerant(Date.self, forKey: .dismissedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, text, resource, goal, projectID, projectName, entryID, createdAt, dismissedAt
    }

    /// Text as kept: line breaks are spaces, spaces at the ends are gone, and
    /// it is no longer than `textLimit`.
    static func clean(_ raw: String) -> String {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
    }

    var isDismissed: Bool { dismissedAt != nil }

    /// A note with neither a step nor a link says nothing, and isn't kept.
    var hasContent: Bool { !text.isEmpty || resource != nil }

    /// What a row calls it: the step, or the goal when the note is only a link.
    var headline: String {
        if !text.isEmpty { return text }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? (resource?.displayName ?? "Next step") : goal
    }

    /// The goal a resumed session starts with: the step, as the note says.
    var sessionGoal: String { headline }

    func projectLabel(in projects: [FocusProject]) -> ProjectLabel? {
        ProjectLabel.of(id: projectID, storedName: projectName, in: projects)
    }
}

// MARK: - Which notes are shown

extension ResumeNote {
    /// Newest first.
    static func newestFirst(_ notes: [ResumeNote]) -> [ResumeNote] {
        notes.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// The one the popover offers: the newest that hasn't been dismissed.
    static func newestUndismissed(in notes: [ResumeNote]) -> ResumeNote? {
        newestFirst(notes).first { !$0.isDismissed }
    }

    /// A project's notes that are still waiting, newest first. These stay
    /// with a project that has been archived or deleted (a deleted project's
    /// notes are listed nowhere, but are still the popover's to offer).
    static func waiting(for projectID: UUID, in notes: [ResumeNote]) -> [ResumeNote] {
        newestFirst(notes).filter { $0.projectID == projectID && !$0.isDismissed }
    }
}

// MARK: - Resuming

/// Why a session can't start right now, in words. Shared by everything that
/// starts one from a button that may be pressed mid-session (a note, a
/// project's page). The model's own `startSession` refuses too; this is so a
/// button can say why before it is pressed.
enum SessionGate {
    static func busyReason(isActive: Bool, isOnBreak: Bool) -> String? {
        if isActive { return "A session is on right now." }
        if isOnBreak { return "A break is on right now." }
        return nil
    }
}

enum ResumeDecision: Equatable, Sendable {
    case start(SessionRequest)
    case refused(String)
}

extension ResumeNote {
    /// What pressing Resume asks for. The goal is the note's step; the
    /// project is the note's, unless it has been deleted, when the session
    /// starts with none. Length and categories are left nil: the popover's
    /// current choices, as for any start. A session or break that is on is
    /// never replaced: it is a refusal, with the reason.
    static func decide(_ note: ResumeNote, projects: [FocusProject], isActive: Bool, isOnBreak: Bool) -> ResumeDecision {
        if let reason = SessionGate.busyReason(isActive: isActive, isOnBreak: isOnBreak) { return .refused(reason) }
        return .start(SessionRequest(goal: note.sessionGoal,
                                     projectID: FocusProject.planFields(for: note.projectID, in: projects)?.id))
    }
}

/// How a note's link fared when it was opened.
enum ResumeLinkResult: Equatable, Sendable {
    case opened
    /// The file or folder isn't where it was; its name, for saying so.
    case missing(String)
    /// The system wouldn't open it.
    case failed(String)
}

/// Resume, with everything it touches passed in, so a test can watch what
/// happens and in what order. The model builds one with the real thing.
@MainActor
struct ResumeRunner {
    var isActive: () -> Bool
    var isOnBreak: () -> Bool
    var projects: () -> [FocusProject]
    /// `NidusModel.startSession`: false when it started nothing.
    var start: (SessionRequest) -> Bool
    /// Opens a note's link. Called only after a session has started.
    var open: (WorkspaceResource) -> ResumeLinkResult
    /// Called once the session has started.
    var dismiss: (UUID) -> Void

    enum Outcome: Equatable, Sendable {
        /// Started; `link` is nil when the note had none.
        case started(link: ResumeLinkResult?)
        /// Nothing happened, and why: a session or break is on.
        case refused(String)
        /// A session or break wasn't on, but none started (a block list with
        /// nothing in it). The note stays.
        case couldNotStart
    }

    func resume(_ note: ResumeNote) -> Outcome {
        switch ResumeNote.decide(note, projects: projects(), isActive: isActive(), isOnBreak: isOnBreak()) {
        case .refused(let reason):
            return .refused(reason)
        case .start(let request):
            guard start(request) else { return .couldNotStart }
            dismiss(note.id)
            return .started(link: note.resource.map(open))
        }
    }
}

// MARK: - Starting a project's session

enum ProjectStart {
    /// What "Start a session" on a project's page asks for, or why not.
    /// Archived projects aren't offered fresh sessions.
    static func decide(_ project: FocusProject, goal: String, isActive: Bool, isOnBreak: Bool) -> ResumeDecision {
        if let reason = SessionGate.busyReason(isActive: isActive, isOnBreak: isOnBreak) { return .refused(reason) }
        if project.isArchived { return .refused("This project is archived. Unarchive it to start a session.") }
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return .start(SessionRequest(goal: trimmed.isEmpty ? nil : trimmed, projectID: project.id))
    }
}
