//
//  ProjectTests.swift
//  NidusTests
//
//  Projects across sessions: the list's edits (ids that stay, nothing in the
//  history touched), what a project's page counts, how a deleted project is
//  named, the CSV's project column, and what starting one asks for. The model
//  isn't built here (it would open the real settings and folder), so each
//  piece is the pure function the model calls.
//

import Foundation
import Testing
@testable import Nidus

struct ProjectListTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func addingMakesAProjectWithItsOwnIdAndKeepsTheOrder() throws {
        guard case .added(let one, let a) = FocusProject.adding("R01 renewal", to: [], now: Self.t0) else {
            Issue.record("expected an addition"); return
        }
        guard case .added(let two, let b) = FocusProject.adding("Lab notebook", to: one, now: Self.t0) else {
            Issue.record("expected an addition"); return
        }
        #expect(two.map(\.name) == ["R01 renewal", "Lab notebook"])
        #expect(a.id != b.id)
        #expect(a.createdAt == Self.t0 && !a.isArchived)
    }

    @Test func aBlankNameAddsNothingAndANameInUseIsNamed() {
        guard case .added(let list, let first) = FocusProject.adding("  Grant  ", to: []) else {
            Issue.record("expected an addition"); return
        }
        #expect(first.name == "Grant", "spaces at the ends are trimmed")
        #expect(FocusProject.adding("   \n ", to: list) == .blank)
        #expect(FocusProject.adding("", to: list) == .blank)
        #expect(FocusProject.adding("grant", to: list) == .duplicate(first), "case does not make a new project")
    }

    @Test func aNameIsOneLineAndNoLongerThanARowHolds() {
        #expect(FocusProject.cleaned("Two\nlines") == "Two lines")
        #expect(FocusProject.cleaned(String(repeating: "x", count: 200)).count == FocusProject.nameLimit)
        #expect(FocusProject(name: "   ").displayName == "Untitled project")
    }

    @Test func renamingKeepsTheIdTheDateAndEveryOtherProject() {
        let a = FocusProject(name: "Grant", createdAt: Self.t0)
        let b = FocusProject(name: "Notebook", createdAt: Self.t0)
        let renamed = FocusProject.renaming(a.id, to: "R01 renewal", in: [a, b])
        #expect(renamed.map(\.id) == [a.id, b.id], "the id is the project, whatever it is called")
        #expect(renamed[0].name == "R01 renewal" && renamed[0].createdAt == Self.t0)
        #expect(renamed[1] == b)
        // Edited live: a space typed between two words is not trimmed away.
        #expect(FocusProject.renaming(a.id, to: "R01 ", in: [a])[0].name == "R01 ")
        #expect(FocusProject.renaming(UUID(), to: "Nobody", in: [a, b]) == [a, b], "an unknown id changes nothing")
    }

    @Test func archivingAndUnarchivingKeepEverythingElse() {
        let a = FocusProject(name: "Grant", createdAt: Self.t0)
        let archived = FocusProject.settingArchived(a.id, to: true, in: [a])
        #expect(archived[0].isArchived && archived[0].id == a.id && archived[0].name == "Grant")
        #expect(FocusProject.settingArchived(a.id, to: false, in: archived) == [a])
        #expect(FocusProject.active(archived).isEmpty)
        #expect(FocusProject.active([a]) == [a])
    }

    @Test func deletingRemovesOnlyThatProject() {
        let a = FocusProject(name: "A"), b = FocusProject(name: "B")
        #expect(FocusProject.removing(a.id, from: [a, b]) == [b])
        #expect(FocusProject.removing(UUID(), from: [a, b]) == [a, b])
    }

    @Test func aChoiceThatIsArchivedOrDeletedFallsBackToNoProject() {
        let live = FocusProject(name: "Live")
        let archived = FocusProject(name: "Old", isArchived: true)
        #expect(FocusProject.choosable(live.id, in: [live, archived]) == live.id)
        #expect(FocusProject.choosable(archived.id, in: [live, archived]) == nil)
        #expect(FocusProject.choosable(UUID(), in: [live]) == nil, "deleted")
        #expect(FocusProject.choosable(nil, in: [live]) == nil)
    }

    @Test func aPlanKeepsTheProjectsIdAndNameAndNeverAnIdThatPointsNowhere() {
        let live = FocusProject(name: "  R01 renewal ")
        let archived = FocusProject(name: "Teaching", isArchived: true)
        let fields = FocusProject.planFields(for: live.id, in: [live, archived])
        #expect(fields?.id == live.id && fields?.name == "R01 renewal")
        #expect(FocusProject.planFields(for: archived.id, in: [live, archived])?.name == "Teaching",
                "an archived project still resolves: finishing work on it is allowed")
        #expect(FocusProject.planFields(for: UUID(), in: [live]) == nil, "deleted: the session starts with no project")
        #expect(FocusProject.planFields(for: nil, in: [live]) == nil)
    }

    @Test func theListIsReadProjectByProject() throws {
        let data = Data(#"[{"id":"\#(UUID().uuidString)","name":"Kept"},{"name":"No id"},{"id":"\#(UUID().uuidString)","name":"Also kept","isArchived":"yes"}]"#.utf8)
        let list = try #require(LossyJSON.list(FocusProject.self, from: data))
        #expect(list.map(\.name) == ["Kept", "Also kept"])
        #expect(list[1].isArchived == false, "a field that doesn't decode loses only itself")
    }

    @Test func theIdSurvivesSavingAndLoading() throws {
        let a = FocusProject(name: "Grant", isArchived: true, createdAt: Self.t0)
        #expect(try JSONDecoder().decode(FocusProject.self, from: JSONEncoder().encode(a)) == a)
    }

    @Test func thePickerShowsOnlyOnceAProjectCanBePicked() {
        #expect(!FocusProjectPickerRow.isVisible(projects: []))
        #expect(!FocusProjectPickerRow.isVisible(projects: [FocusProject(name: "Old", isArchived: true)]))
        #expect(FocusProjectPickerRow.isVisible(projects: [FocusProject(name: "Old", isArchived: true), FocusProject(name: "New")]))
    }
}

// MARK: - Renaming, archiving and deleting leave history alone

struct ProjectHistoryTests {
    static func entry(_ project: FocusProject?, name: String? = nil, goal: String = "Aims", minutes: Double = 25,
                      finished: Bool? = nil) -> SessionEntry {
        SessionEntry(start: StatsTests.day(-1), end: StatsTests.day(-1).addingTimeInterval(minutes * 60), focused: minutes * 60,
                     planned: minutes * 60, outcome: .completed, goal: goal, finished: finished,
                     projectID: project?.id, projectName: name ?? project?.name)
    }

    @MainActor
    @Test func editingTheListNeverChangesWhatTheHistoryRecorded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let grant = FocusProject(name: "Grant")
        let history = FocusHistory(url: url)
        [Self.entry(grant, finished: false), Self.entry(grant, finished: true), Self.entry(nil)].forEach(history.append)
        let before = try Data(contentsOf: url)
        let entries = history.sessions

        // The edits take the list, never the history.
        var list = [grant]
        list = FocusProject.renaming(grant.id, to: "R01 renewal", in: list)
        list = FocusProject.settingArchived(grant.id, to: true, in: list)
        list = FocusProject.removing(grant.id, from: list)

        #expect(list.isEmpty)
        #expect(try Data(contentsOf: url) == before, "the history file is byte for byte as it was")
        #expect(FocusHistory(url: url).sessions == entries)
        #expect(entries[0].projectID == grant.id && entries[0].projectName == "Grant")
    }

    @Test func aRenamedProjectShowsItsNewNameAndADeletedOneItsOldName() {
        let grant = FocusProject(name: "Grant")
        let recorded = Self.entry(grant)
        let renamed = FocusProject.renaming(grant.id, to: "R01 renewal", in: [grant])
        #expect(ProjectLabel.of(id: recorded.projectID, storedName: recorded.projectName, in: renamed)?.text == "R01 renewal")
        #expect(recorded.projectName == "Grant", "what was recorded is not rewritten")
        let deleted = FocusProject.removing(grant.id, from: renamed)
        let label = ProjectLabel.of(id: recorded.projectID, storedName: recorded.projectName, in: deleted)
        #expect(label?.text == "Grant (deleted)")
        #expect(label?.state == .deleted)
    }

    @Test func labelsSayArchivedAndNameARecordThatKeptNoName() {
        let archived = FocusProject(name: "Teaching", isArchived: true)
        #expect(ProjectLabel.of(id: archived.id, storedName: nil, in: [archived])?.text == "Teaching (archived)")
        #expect(ProjectLabel.of(id: UUID(), storedName: nil, in: [])?.text == "A deleted project")
        #expect(ProjectLabel.of(id: nil, storedName: nil, in: []) == nil, "no project at all")
        #expect(ProjectLabel.of(id: nil, storedName: "Orphan", in: [])?.text == "Orphan (deleted)")
    }

    @Test func aSessionKeepsTheProjectItsPlanHad() throws {
        var plan = SessionPlan(goal: "Aims", duration: 1500, mode: .block, apps: [], websites: [])
        let grant = FocusProject(name: "Grant")
        let fields = try #require(FocusProject.planFields(for: grant.id, in: [grant]))
        plan.projectID = fields.id
        plan.projectName = fields.name
        var state = SessionState(plan: plan, startedAt: Date(), phase: .running(deadline: Date()), budget: 1500)
        state.focusedTime = 1500
        state.endedAt = Date()
        let entry = try #require(SessionEntry(ended: state, outcome: .completed))
        #expect(entry.projectID == grant.id && entry.projectName == "Grant")
    }

    @MainActor
    @Test func anEntryFromBeforeProjectsLoadsWithNone() throws {
        let legacy = MigrationTests.legacyEntry(goal: "Old goal")
        let file = try JSONDecoder().decode(FocusHistory.File.self, from: Data(#"{"version":1,"sessions":[\#(legacy)]}"#.utf8))
        #expect(file.sessions[0].projectID == nil && file.sessions[0].projectName == nil)
        let grant = FocusProject(name: "Grant")
        let roster = ProjectSummary.roster(projects: [grant], sessions: file.sessions)
        #expect(roster.live[0].summary.sessionCount == 0, "a session with no project belongs to none")
        #expect(roster.deleted.isEmpty, "and is not a deleted project")
        #expect(ProjectSummary(projectID: nil, sessions: file.sessions).sessionCount == 1)
    }
}

// MARK: - What a project's page counts

struct ProjectSummaryTests {
    static let grant = FocusProject(name: "R01 renewal")
    static let notebook = FocusProject(name: "Lab notebook")

    static func entry(_ project: FocusProject?, day: Int, minutes: Double, goal: String = "", finished: Bool? = nil,
                      outcome: SessionEndReason = .completed, name: String? = nil, hour: Int = 10) -> SessionEntry {
        let start = StatsTests.day(day, hour: hour)
        return SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60), focused: minutes * 60, planned: 45 * 60,
                            outcome: outcome, goal: goal, finished: finished,
                            projectID: project?.id, projectName: name ?? project?.name)
    }

    @Test func focusedTimeCountsOnlyTheProjectsSessionsAndNeverThePauses() {
        // A session 40 minutes long on the clock with 10 of them paused: its
        // `focused` is 30, and that is what counts.
        let start = StatsTests.day(-1)
        let paused = SessionEntry(start: start, end: start.addingTimeInterval(40 * 60), focused: 30 * 60, planned: 40 * 60,
                                  outcome: .completed, projectID: Self.grant.id, projectName: "R01 renewal")
        let sessions = [paused, Self.entry(Self.grant, day: -2, minutes: 25), Self.entry(Self.notebook, day: -2, minutes: 90),
                        Self.entry(nil, day: -2, minutes: 15)]
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions)
        #expect(summary.focused == 55 * 60)
        #expect(summary.sessionCount == 2)
        #expect(ProjectSummary(projectID: Self.notebook.id, sessions: sessions).focused == 90 * 60)
    }

    @Test func breaksAreNotSessionsSoTheyAreNeverCounted() {
        // A break is never a history entry: with three work sessions in the
        // history, three is the count, whatever breaks lay between them.
        let sessions = (1...3).map { Self.entry(Self.grant, day: -$0, minutes: 25) }
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions)
        #expect(summary.sessionCount == 3 && summary.focused == 75 * 60)
    }

    @Test func anIncompleteSessionCountsItsFocusedTimeButNotAsCompleted() {
        let sessions = [Self.entry(Self.grant, day: -1, minutes: 45),
                        Self.entry(Self.grant, day: -2, minutes: 10, outcome: .endedEarly),
                        Self.entry(Self.grant, day: -3, minutes: 5, outcome: .expiredWhileAway)]
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions)
        #expect(summary.sessionCount == 3)
        #expect(summary.completedCount == 1)
        #expect(summary.focused == 60 * 60, "ended early still counts the time it ran")
    }

    @Test func unfinishedGoalsAreTheOnesAnsweredNotYet() {
        let sessions = [Self.entry(Self.grant, day: -1, minutes: 25, goal: "Budget", finished: false),
                        Self.entry(Self.grant, day: -2, minutes: 25, goal: "Aims", finished: true),
                        Self.entry(Self.grant, day: -3, minutes: 25, goal: "Never asked", finished: nil),
                        Self.entry(Self.grant, day: -4, minutes: 25, goal: "", finished: false),
                        Self.entry(Self.notebook, day: -1, minutes: 25, goal: "Other project", finished: false)]
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions)
        #expect(summary.unfinished.map(\.goal) == ["Budget"])
    }

    @Test func aGoalWorkedOnOverSeveralSessionsIsListedOnceAndNotAtAllOnceFinished() {
        let sessions = [Self.entry(Self.grant, day: -1, minutes: 25, goal: "Aims", finished: false),
                        Self.entry(Self.grant, day: -2, minutes: 25, goal: "aims ", finished: false),
                        Self.entry(Self.grant, day: -3, minutes: 25, goal: "Budget", finished: false),
                        Self.entry(Self.grant, day: -2, minutes: 25, goal: "Budget", finished: true, hour: 14)]
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions)
        #expect(summary.unfinished.map { $0.goal.trimmingCharacters(in: .whitespaces).lowercased() } == ["aims"],
                "Aims once, by its newest; Budget was finished since")
        #expect(summary.unfinished.first?.start == StatsTests.day(-1))
    }

    @Test func recentSessionsAreNewestFirstAndFew() {
        let sessions = (1...8).map { Self.entry(Self.grant, day: -$0, minutes: Double($0 * 5)) }
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: sessions.shuffled())
        #expect(summary.recent.count == ProjectSummary.recentLimit)
        #expect(summary.recent.map(\.start) == (1...5).map { StatsTests.day(-$0) })
    }

    @Test func aProjectWithNoSessionsHasNothingToShow() {
        let summary = ProjectSummary(projectID: Self.grant.id, sessions: [])
        #expect(summary.sessionCount == 0 && summary.focused == 0 && summary.recent.isEmpty && summary.unfinished.isEmpty)
    }

    @Test func theRosterListsLiveProjectsArchivedLastThenTheDeletedOnesHistoryStillNames() {
        let archived = FocusProject(name: "Teaching", isArchived: true)
        let gone = FocusProject(name: "Old pilot")
        let sessions = [Self.entry(Self.grant, day: -1, minutes: 25),
                        Self.entry(gone, day: -5, minutes: 40, name: "Old pilot"),
                        Self.entry(gone, day: -3, minutes: 20, name: "Old pilot (renamed)"),
                        Self.entry(nil, day: -1, minutes: 10)]
        let roster = ProjectSummary.roster(projects: [archived, Self.grant, Self.notebook], sessions: sessions)
        #expect(roster.live.map(\.project.name) == ["R01 renewal", "Lab notebook", "Teaching"])
        #expect(roster.live[0].summary.focused == 25 * 60)
        #expect(roster.live[1].summary.sessionCount == 0)
        #expect(roster.deleted.count == 1)
        #expect(roster.deleted[0].projectID == gone.id)
        #expect(roster.deleted[0].focused == 60 * 60)
        #expect(roster.deleted[0].recordedName == "Old pilot (renamed)", "the newest name it was recorded with")
    }

    @MainActor
    @Test func clearingHistoryClearsWhatProjectsAreCountedFrom() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = FocusHistory(url: url)
        history.append(Self.entry(Self.grant, day: -1, minutes: 25))
        #expect(ProjectSummary(projectID: Self.grant.id, sessions: history.sessions).sessionCount == 1)
        history.clear()
        #expect(ProjectSummary(projectID: Self.grant.id, sessions: history.sessions).sessionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Export

struct ProjectExportTests {
    static let la = ZonedCalendar("America/Los_Angeles")

    @Test func theProjectColumnIsLastAndTheOthersAreAsTheyWere() {
        #expect(HistoryExport.csvColumns == ["start", "end", "planned_minutes", "focused_minutes", "completed",
                                             "goal", "finished", "blocked_count", "most_blocked", "project"])
        let grant = FocusProject(name: "R01 renewal")
        let entry = ProjectHistoryTests.entry(grant, goal: "Aims")
        let rows = parseCSV(HistoryExport.csv([entry], timeZone: Self.la.calendar.timeZone))
        #expect(rows[1].count == HistoryExport.csvColumns.count)
        #expect(rows[1][9] == "R01 renewal")
        #expect(Array(rows[1][5...6]) == ["Aims", ""], "goal and finished sit where they did")
    }

    @Test func aSessionWithNoProjectHasAnEmptyCell() {
        let rows = parseCSV(HistoryExport.csv([ProjectHistoryTests.entry(nil)], timeZone: Self.la.calendar.timeZone))
        #expect(rows[1].last == "")
        #expect(rows[1].count == 10)
    }

    @Test func theCellIsTheNameTheSessionRecordedAndIsQuotedWhenItNeedsIt() {
        let grant = FocusProject(name: "Grant")
        let old = ProjectHistoryTests.entry(grant, name: "Grant, \"phase 1\"")
        let renamed = FocusProject.renaming(grant.id, to: "R01 renewal", in: [grant])
        _ = renamed
        let rows = parseCSV(HistoryExport.csv([old], timeZone: Self.la.calendar.timeZone))
        #expect(rows[1][9] == "Grant, \"phase 1\"", "what was recorded, not the name now")
    }

    @Test func theJSONCarriesTheProjectAsStored() throws {
        let grant = FocusProject(name: "R01 renewal")
        let sessions = [ProjectHistoryTests.entry(grant, finished: false), ProjectHistoryTests.entry(nil)]
        let file = try JSONDecoder().decode(FocusHistory.File.self, from: HistoryExport.json(sessions))
        #expect(file.sessions == sessions)
        #expect(file.sessions[0].projectID == grant.id && file.sessions[0].projectName == "R01 renewal")
    }
}

// MARK: - Starting

struct ProjectStartTests {
    static let grant = FocusProject(name: "R01 renewal")

    @Test func startingAsksForTheProjectWithTheGoalTypedOrNone() {
        #expect(ProjectStart.decide(Self.grant, goal: "  Aims  ", isActive: false, isOnBreak: false)
                == .start(SessionRequest(goal: "Aims", projectID: Self.grant.id)))
        #expect(ProjectStart.decide(Self.grant, goal: "   ", isActive: false, isOnBreak: false)
                == .start(SessionRequest(goal: nil, projectID: Self.grant.id)))
    }

    @Test func aSessionOrBreakThatIsOnIsNeverReplacedAndTheReasonIsGiven() {
        let session = ProjectStart.decide(Self.grant, goal: "x", isActive: true, isOnBreak: false)
        let rest = ProjectStart.decide(Self.grant, goal: "x", isActive: false, isOnBreak: true)
        #expect(session == .refused("A session is on right now."))
        #expect(rest == .refused("A break is on right now."))
        #expect(SessionGate.busyReason(isActive: false, isOnBreak: false) == nil)
    }

    @Test func anArchivedProjectIsNotOfferedAFreshSession() {
        var archived = Self.grant
        archived.isArchived = true
        guard case .refused(let reason) = ProjectStart.decide(archived, goal: "", isActive: false, isOnBreak: false) else {
            Issue.record("expected a refusal"); return
        }
        #expect(reason.contains("archived"))
        // A busy session is named first: it is the reason it can't start now.
        #expect(ProjectStart.decide(archived, goal: "", isActive: true, isOnBreak: false) == .refused("A session is on right now."))
    }
}

// MARK: - The popover's choice and the wrap-up

struct ProjectChoiceTests {
    @Test func theNextStartUsesTheChoiceOnlyWhileItIsStillOffered() {
        let live = FocusProject(name: "Live")
        var archived = live
        archived.isArchived = true
        #expect(FocusProject.choosable(live.id, in: [live]) == live.id)
        #expect(FocusProject.choosable(live.id, in: [archived]) == nil, "archived since: reads as none, quietly")
        #expect(FocusProject.choosable(live.id, in: []) == nil, "deleted since")
    }
}
