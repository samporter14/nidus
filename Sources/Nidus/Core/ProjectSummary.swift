//
//  ProjectSummary.swift
//  Nidus
//
//  What one project's page shows, worked out from the history. Pure, like
//  FocusStats (which it is built on), so the tests can feed it awkward
//  histories. Nothing is stored: with history off no session is recorded, so
//  there is nothing to count, and Clear History takes these numbers with it.
//
//  Time is `SessionEntry.focused`, which already leaves out pauses; a break
//  is never a session entry, so it is never counted here either.
//

import Foundation

struct ProjectSummary: Equatable, Sendable {
    /// nil for the sessions that belong to no project.
    var projectID: UUID?
    /// The name the newest session recorded for it. A live project shows its
    /// own current name instead; this is for one that has been deleted.
    var recordedName: String?
    /// Counts and totals over this project's sessions, from the same code as
    /// the Stats page: `sessionCount`, `completedCount`, `totalFocused` and
    /// the rest.
    var stats: FocusStats
    /// Newest first, at most `recentLimit`.
    var recent: [SessionEntry]
    /// Goals answered "Not yet" and not finished since, newest first. A goal
    /// that a later session of the project finished is not listed, and a goal
    /// worked on over several sessions is listed once, by its newest.
    var unfinished: [SessionEntry]

    static let recentLimit = 5

    var focused: TimeInterval { stats.totalFocused }
    var sessionCount: Int { stats.sessionCount }
    var completedCount: Int { stats.completedCount }

    /// The summary for `projectID` (nil: sessions with none) over `sessions`.
    init(projectID: UUID?, sessions: [SessionEntry], recentLimit: Int = Self.recentLimit) {
        self.init(projectID: projectID, entries: sessions.filter { $0.projectID == projectID }, recentLimit: recentLimit)
    }

    /// `entries` are already this project's.
    private init(projectID: UUID?, entries: [SessionEntry], recentLimit: Int) {
        self.projectID = projectID
        let newestFirst = entries.sorted { $0.start > $1.start }
        recordedName = newestFirst.lazy.compactMap { entry in
            let name = entry.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name?.isEmpty ?? true) ? nil : name
        }.first
        stats = FocusStats(sessions: entries, weeks: 1)
        recent = Array(newestFirst.prefix(recentLimit))
        unfinished = Self.unfinishedGoals(in: newestFirst)
    }

    /// Entries answered "Not yet", one per goal, minus any goal finished by a
    /// newer session. `newestFirst` must be in that order.
    static func unfinishedGoals(in newestFirst: [SessionEntry]) -> [SessionEntry] {
        func key(_ goal: String) -> String {
            goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var settled: Set<String> = []   // goals whose newest answer is already known
        var result: [SessionEntry] = []
        for entry in newestFirst {
            let goal = key(entry.goal)
            guard !goal.isEmpty, let finished = entry.finished, !settled.contains(goal) else { continue }
            settled.insert(goal)
            if !finished { result.append(entry) }
        }
        return result
    }

    // MARK: Every project at once

    /// One row of the Projects list.
    struct Row: Equatable, Sendable, Identifiable {
        var project: FocusProject
        var summary: ProjectSummary
        var id: UUID { project.id }
    }

    /// The Projects list: every project that exists, with its numbers, and
    /// the projects history still names that no longer exist.
    struct Roster: Equatable, Sendable {
        /// In the order they were made, archived ones last.
        var live: [Row]
        /// By most recent session first. Shown as "Name (deleted)".
        var deleted: [ProjectSummary]
    }

    static func roster(projects: [FocusProject], sessions: [SessionEntry]) -> Roster {
        // One pass over the history, not one per project.
        let byProject = Dictionary(grouping: sessions.filter { $0.projectID != nil }, by: { $0.projectID! })
        let known = Set(projects.map(\.id))
        let live = (projects.filter { !$0.isArchived } + projects.filter(\.isArchived)).map { project in
            Row(project: project,
                summary: ProjectSummary(projectID: project.id, entries: byProject[project.id] ?? [], recentLimit: recentLimit))
        }
        let deleted = byProject.filter { !known.contains($0.key) }
            .map { ProjectSummary(projectID: $0.key, entries: $0.value, recentLimit: recentLimit) }
            .sorted { ($0.recent.first?.start ?? .distantPast) > ($1.recent.first?.start ?? .distantPast) }
        return Roster(live: live, deleted: deleted)
    }
}
