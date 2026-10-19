//
//  ResumeNoteTests.swift
//  NidusTests
//
//  Resume notes: written after "Did you finish?" is answered either way (or
//  with sessions not recorded), kept in their own file note by note, offered
//  until dismissed, and resumed only through the one start path, with the
//  link opened only on that click. Temporary folders and fakes throughout:
//  nothing here starts a session or opens a file.
//

import Foundation
import Testing
@testable import Nidus

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

struct ResumeNoteValueTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theTextIsOneLineAndNoLongerThanTheLimit() {
        #expect(ResumeNote.textLimit == 160)
        #expect(ResumeNote.clean("  Add the\npower analysis \n") == "Add the power analysis")
        #expect(ResumeNote(text: String(repeating: "a", count: 400)).text.count == 160)
        #expect(ResumeNote(text: "   ").text == "")
    }

    @Test func aNoteWithNeitherAStepNorALinkSaysNothing() {
        #expect(!ResumeNote(text: "").hasContent)
        #expect(ResumeNote(text: "x").hasContent)
        let link = ResumeResources.webPage(from: "example.org/aims")
        #expect(ResumeNote(text: "", resource: link).hasContent)
    }

    @Test func aLinkOnlyNoteIsNamedByItsGoal() {
        let link = ResumeResources.webPage(from: "example.org/aims")
        #expect(ResumeNote(text: "", resource: link, goal: "Update Aims").headline == "Update Aims")
        #expect(ResumeNote(text: "", resource: link).headline == "example.org/aims")
        #expect(ResumeNote(text: "Run it", goal: "Update Aims").sessionGoal == "Run it")
    }

    @Test func everyFieldSurvivesSavingAndLoading() throws {
        let note = ResumeNote(text: "Rerun Figure 3", resource: ResumeResources.webPage(from: "https://example.org/fig"),
                              goal: "Figures", projectID: UUID(), projectName: "R01", entryID: UUID(),
                              createdAt: Self.t0, dismissedAt: Self.t0.addingTimeInterval(60))
        #expect(try JSONDecoder().decode(ResumeNote.self, from: JSONEncoder().encode(note)) == note)
    }

    @Test func aFieldThatDoesNotDecodeLosesOnlyItself() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","text":"Keep me","resource":42,"projectID":"not-a-uuid","dismissedAt":"later","goal":"G"}"#
        let note = try JSONDecoder().decode(ResumeNote.self, from: Data(json.utf8))
        #expect(note.text == "Keep me" && note.goal == "G")
        #expect(note.resource == nil && note.projectID == nil && note.dismissedAt == nil)
    }

    @Test func aTextWrittenLongerByHandIsCutOnReading() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"\#(String(repeating: "b", count: 300))"}"#
        #expect(try JSONDecoder().decode(ResumeNote.self, from: Data(json.utf8)).text.count == 160)
    }

    @Test func theNewestUndismissedNoteIsTheOneOffered() {
        let old = ResumeNote(text: "old", createdAt: Self.t0)
        let newest = ResumeNote(text: "newest", createdAt: Self.t0.addingTimeInterval(200))
        var dismissed = ResumeNote(text: "newer but dismissed", createdAt: Self.t0.addingTimeInterval(400))
        dismissed.dismissedAt = Self.t0.addingTimeInterval(500)
        #expect(ResumeNote.newestUndismissed(in: [old, dismissed, newest])?.text == "newest")
        #expect(ResumeNote.newestUndismissed(in: [dismissed]) == nil)
        #expect(ResumeNote.newestUndismissed(in: []) == nil)
    }

    @Test func aProjectsWaitingNotesAreItsOwnUndismissedOnesNewestFirst() {
        let grant = UUID(), other = UUID()
        let a = ResumeNote(text: "a", projectID: grant, createdAt: Self.t0)
        let b = ResumeNote(text: "b", projectID: grant, createdAt: Self.t0.addingTimeInterval(10))
        var c = ResumeNote(text: "c", projectID: grant, createdAt: Self.t0.addingTimeInterval(20))
        c.dismissedAt = Self.t0
        let d = ResumeNote(text: "d", projectID: other, createdAt: Self.t0.addingTimeInterval(30))
        #expect(ResumeNote.waiting(for: grant, in: [a, b, c, d]).map(\.text) == ["b", "a"])
    }

    @Test func aMissingOrDeletedProjectIsNamedAsSuch() {
        let grant = FocusProject(name: "R01 renewal")
        let note = ResumeNote(text: "x", projectID: grant.id, projectName: "Grant")
        #expect(note.projectLabel(in: [grant])?.text == "R01 renewal", "a live project shows its name now")
        #expect(note.projectLabel(in: [])?.text == "Grant (deleted)")
        #expect(ResumeNote(text: "x").projectLabel(in: [grant]) == nil)
    }
}

// MARK: - The file

@MainActor
struct ResumeNoteStoreTests {
    @Test func aNoteIsSavedAtomicallyAndReadBack() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        #expect(ResumeNoteStore.fileName == "resume-notes.json")
        let store = ResumeNoteStore(url: url)
        let note = ResumeNote(text: "Add the power analysis", goal: "Aims", entryID: UUID())
        store.add(note)
        #expect(ResumeNoteStore(url: url).notes == [note])
        // Atomic: nothing but the file is left in the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["resume-notes.json"])
    }

    @Test func oneMalformedNoteLeavesTheGoodOnes() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        let good = #"{"id":"\#(UUID().uuidString)","text":"First"}"#
        let noID = #"{"text":"No id"}"#
        let notAnObject = "17"
        let alsoGood = #"{"id":"\#(UUID().uuidString)","text":"Second","projectID":"nonsense"}"#
        let empty = #"{"id":"\#(UUID().uuidString)","text":"  "}"#
        try Data(#"{"version":1,"notes":[\#(good),\#(noID),\#(notAnObject),\#(alsoGood),\#(empty)]}"#.utf8).write(to: url)
        let store = ResumeNoteStore(url: url)
        #expect(store.notes.map(\.text) == ["First", "Second"], "bad elements and notes that say nothing are dropped")
        // And the next save keeps them rather than writing the file empty.
        store.add(ResumeNote(text: "Third"))
        #expect(ResumeNoteStore(url: url).notes.map(\.text) == ["First", "Second", "Third"])
    }

    @Test func aFileThatIsNotANotesFileIsSetAsideIntact() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        try Data("{ not json".utf8).write(to: url)
        let store = ResumeNoteStore(url: url)
        #expect(store.notes.isEmpty)
        store.add(ResumeNote(text: "New"))
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("resume-notes.unreadable-") })
        #expect(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8) == "{ not json")
        #expect(ResumeNoteStore(url: url).notes.map(\.text) == ["New"])
    }

    @Test func dismissingKeepsTheNoteAndSavesWhenItWasDismissed() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        let store = ResumeNoteStore(url: url)
        let note = ResumeNote(text: "Next")
        store.add(note)
        let when = Date(timeIntervalSinceReferenceDate: 810_000_000)
        #expect(store.dismiss(note.id, at: when))
        #expect(ResumeNoteStore(url: url).notes.first?.dismissedAt == when)
        // Dismissed twice keeps the first time.
        store.dismiss(note.id, at: when.addingTimeInterval(500))
        #expect(store.notes.first?.dismissedAt == when)
        #expect(!store.dismiss(UUID()), "an unknown note changes nothing")
    }

    @Test func clearingRemovesTheNotesAndTheFile() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        let store = ResumeNoteStore(url: url)
        store.add(ResumeNote(text: "a"))
        store.add(ResumeNote(text: "b"))
        store.clear()
        #expect(store.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pastTheLimitTheOldestDismissedNotesGoFirst() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let t0 = ResumeNoteValueTests.t0
        var oldestWaiting = ResumeNote(text: "oldest but waiting", createdAt: t0)
        oldestWaiting.dismissedAt = nil
        store.add(oldestWaiting)
        for i in 1...ResumeNoteStore.limit {
            var note = ResumeNote(text: "n\(i)", createdAt: t0.addingTimeInterval(Double(i)))
            note.dismissedAt = t0
            store.add(note)
        }
        #expect(store.notes.count == ResumeNoteStore.limit)
        #expect(store.notes.contains { $0.text == "oldest but waiting" }, "a note still waiting is kept over dismissed ones")
        #expect(!store.notes.contains { $0.text == "n1" })
    }

    @Test func clearHistoryClearsTheNotesAndSaysSo() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        let model = NidusModel()
        let store = ResumeNoteStore(url: url)
        store.add(ResumeNote(text: "Next step"))
        model.resumeNotes = store
        model.clearHistory()
        #expect(model.resumeNoteList.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FocusStatsPage.clearHistoryMessage.contains("resume notes"))
        #expect(FocusStatsPage.clearHistoryMessage.contains("Your projects stay"))
    }

    @Test func dismissingFromTheModelOpensNothingAndStartsNothing() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = NidusModel()
        var opened: [URL] = []
        model.urlOpener = { opened.append($0); return true }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let note = ResumeNote(text: "Next", resource: ResumeResources.webPage(from: "example.org/aims"))
        store.add(note)
        model.resumeNotes = store
        model.dismissResumeNote(note.id)
        #expect(model.newestResumeNote == nil)
        #expect(opened.isEmpty, "a link opens only when its note is resumed")
        #expect(!model.isActive)
    }
}

// MARK: - Writing a note on the wrap-up card

@MainActor
struct NextStepTests {
    static func entry(finished: Bool?, goal: String = "Update Specific Aims") -> SessionEntry {
        SessionEntry(start: StatsTests.day(-1), end: StatsTests.day(-1).addingTimeInterval(1500), focused: 1500, planned: 1500,
                     outcome: .completed, goal: goal, finished: finished)
    }

    static func session(store: ResumeNoteStore, entry: SessionEntry? = nil, project: FocusProject? = nil,
                        historyOff: Bool = false) -> NextStepSession {
        NextStepSession(seed: .init(goal: entry?.goal ?? "Update Specific Aims", projectID: project?.id, projectName: project?.name,
                                    entryID: entry?.id),
                        historyIsOff: historyOff, store: store, now: { ResumeNoteValueTests.t0 })
    }

    @Test(arguments: [true, false])
    func aNoteIsSavedAfterEitherAnswerAndTheAnswerIsNotTouched(_ finished: Bool) throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = FocusHistory(url: folder.appendingPathComponent("history.json"))
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let entry = Self.entry(finished: nil)
        history.append(entry)
        history.setFinished(entry.id, finished)
        let grant = FocusProject(name: "R01 renewal")
        let step = Self.session(store: store, entry: entry, project: grant)

        step.setText("Add the power analysis to Aim 2")
        let note = try #require(store.notes.first)
        #expect(note.text == "Add the power analysis to Aim 2")
        #expect(note.goal == "Update Specific Aims")
        #expect(note.entryID == entry.id, "kept with the session it follows")
        #expect(note.projectID == grant.id && note.projectName == "R01 renewal")
        #expect(note.createdAt == ResumeNoteValueTests.t0 && note.dismissedAt == nil)
        #expect(history.sessions[0].finished == finished)
    }

    @Test func editingDismissingAndClearingANeverChangeTheHistory() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let historyURL = folder.appendingPathComponent("history.json")
        let history = FocusHistory(url: historyURL)
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let notYet = Self.entry(finished: false), yes = Self.entry(finished: true, goal: "Other")
        history.append(notYet)
        history.append(yes)
        let before = try Data(contentsOf: historyURL)

        let step = Self.session(store: store, entry: notYet)
        step.setText("First thought")
        step.setText("Second thought")
        step.setResource(ResumeResources.webPage(from: "example.org/aims"))
        store.dismiss(try #require(step.noteID))
        store.clear()
        step.setText("Written again after a clear")

        #expect(try Data(contentsOf: historyURL) == before, "the history file is byte for byte as it was")
        #expect(FocusHistory(url: historyURL).sessions.map(\.finished) == [false, true])
    }

    @Test func nothingTypedMeansNoNoteAndEmptyingTakesItBack() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = Self.session(store: store)
        step.setText("   ")
        #expect(store.notes.isEmpty && !step.isSaved, "skipping leaves nothing behind")
        step.setText("A step")
        #expect(store.notes.count == 1 && step.isSaved)
        step.setText("")
        #expect(store.notes.isEmpty && !step.isSaved)
    }

    @Test func eachEditIsKeptAsItIsMadeAndIsOneNote() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ResumeNoteStore.fileName)
        let store = ResumeNoteStore(url: url)
        let step = Self.session(store: store)
        var changes = 0
        step.onChange = { changes += 1 }
        for text in ["R", "Re", "Rer", "Rerun it"] { step.setText(text) }
        #expect(changes == 4)
        #expect(ResumeNoteStore(url: url).notes.map(\.text) == ["Rerun it"], "a card that goes away mid-sentence loses nothing")
    }

    @Test func aTypedSentenceKeepsItsSpacesButIsStoredTrimmed() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = Self.session(store: store)
        step.setText("Rerun ")
        #expect(step.text == "Rerun ", "the field must not eat the space as it is typed")
        #expect(store.notes[0].text == "Rerun")
        step.setText(String(repeating: "z", count: 300))
        #expect(step.text.count == 160 && store.notes[0].text.count == 160)
    }

    @Test func aLinkAloneIsEnoughForANote() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = Self.session(store: store)
        step.setResource(ResumeResources.webPage(from: "example.org/aims"))
        #expect(store.notes.count == 1 && store.notes[0].text.isEmpty)
        step.setResource(nil)
        #expect(store.notes.isEmpty)
    }

    @Test func withHistoryOffTheNoteIsStillKeptWithNoEntryAndTheCardSaysSo() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = Self.session(store: store, historyOff: true)
        #expect(step.historyOffCaption == "Session history is off. Only this note is kept.")
        step.setText("Check the controls")
        #expect(store.notes.count == 1)
        #expect(store.notes[0].entryID == nil, "there is no history entry to point to")
        #expect(step.historyOffCaption == "Saved as a note. Session history is off.")
    }

    @Test func aProjectDeletedBeforeTheNoteIsWrittenLeavesTheNoteWithItsName() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let grant = FocusProject(name: "R01 renewal")
        let step = Self.session(store: store, project: grant)
        step.setText("Next")
        let list = FocusProject.removing(grant.id, from: [grant])
        #expect(store.notes[0].projectLabel(in: list)?.text == "R01 renewal (deleted)")
        #expect(ResumeNote.decide(store.notes[0], projects: list, isActive: false, isOnBreak: false)
                == .start(SessionRequest(goal: "Next", projectID: nil)), "resumed with no project")
    }

    @Test func aNoteIsOnlyOfferedForASessionWithAGoalThatWasLongEnoughToCount() {
        // beginNextStep needs a model with a notes file; one without has none to write to.
        let model = NidusModel()
        let plan = SessionPlan(goal: "Aims", duration: 1500, mode: .block, apps: [], websites: [])
        var state = SessionState(plan: plan, startedAt: Date(), phase: .running(deadline: Date()), budget: 1500)
        state.focusedTime = 1500
        #expect(model.beginNextStep(for: state, entry: nil) == nil, "no notes file, no field")
    }

    @Test func plaqueIsToldTheStepOnceTypingSettlesNotAtEveryLetter() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = NextStepSession(seed: .init(goal: "Aims", projectID: nil, projectName: nil, entryID: nil),
                                   historyIsOff: false, store: store, settleDelay: .milliseconds(30))
        var told: [String?] = []
        step.onSettled = { told.append($0) }
        for text in ["R", "Re", "Rerun it "] { step.setText(text) }
        #expect(told.isEmpty, "nothing yet: the person is still typing")
        try await Task.sleep(for: .milliseconds(400))
        #expect(told == ["Rerun it"], "one report, the step as it is kept")
    }

    @Test func doneReportsTheStepAtOnceAndOnlyWhenItChanged() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let step = Self.session(store: store)
        var told: [String?] = []
        step.onSettled = { told.append($0) }
        step.settleNow()
        #expect(told.isEmpty, "skipping says nothing: there was no step and still is none")
        step.setText("Check the controls")
        step.settleNow()
        step.settleNow()
        #expect(told == ["Check the controls"])
        step.setText("")
        step.settleNow()
        #expect(told == ["Check the controls", nil], "taking the step back tells Plaque there is none")
    }

    @Test func theCardStaysLongEnoughToTypeIn() {
        #expect(FinishReply.noteLinger > FinishReply.linger)
        #expect(FinishReply.noteLinger >= 15)
    }
}

// MARK: - Resuming

@MainActor
struct ResumeTests {
    static let grant = FocusProject(name: "R01 renewal")

    static func note(link: WorkspaceResource? = nil) -> ResumeNote {
        note(project: grant, link: link)
    }

    static func note(project: FocusProject?, link: WorkspaceResource?) -> ResumeNote {
        ResumeNote(text: "Add the power analysis", resource: link, goal: "Update Aims",
                   projectID: project?.id, projectName: project?.name)
    }

    /// Everything a resume touches, recorded in order.
    @MainActor final class Spy {
        var calls: [String] = []
        var active = false, onBreak = false
        var startResult = true
        var linkResult: ResumeLinkResult = .opened
        var projects = [ResumeTests.grant]
        var started: [SessionRequest] = []
        var opened: [WorkspaceResource] = []
        var dismissed: [UUID] = []

        var runner: ResumeRunner {
            ResumeRunner(isActive: { self.active }, isOnBreak: { self.onBreak }, projects: { self.projects },
                         start: { request in self.calls.append("start"); self.started.append(request); return self.startResult },
                         open: { resource in self.calls.append("open"); self.opened.append(resource); return self.linkResult },
                         dismiss: { id in self.calls.append("dismiss"); self.dismissed.append(id) })
        }
    }

    @Test func resumingAsksForTheStepAsTheGoalAndTheNotesProject() {
        let decision = ResumeNote.decide(Self.note(), projects: [Self.grant], isActive: false, isOnBreak: false)
        #expect(decision == .start(SessionRequest(goal: "Add the power analysis", projectID: Self.grant.id)))
        guard case .start(let request) = decision else { return }
        #expect(request.minutes == nil && request.categoryIDs == nil, "the popover's length and categories, as any start")
    }

    @Test func aSessionOnRefusesAndSaysWhyAndNothingElseHappens() {
        let spy = Spy()
        spy.active = true
        let link = ResumeResources.webPage(from: "example.org/aims")
        #expect(spy.runner.resume(Self.note(link: link)) == .refused("A session is on right now."))
        #expect(spy.calls.isEmpty, "nothing started, nothing opened, the note not dismissed")
    }

    @Test func aBreakOnRefusesToo() {
        let spy = Spy()
        spy.onBreak = true
        #expect(spy.runner.resume(Self.note()) == .refused("A break is on right now."))
        #expect(spy.calls.isEmpty)
    }

    @Test func aStartedResumeOpensTheLinkOnceAfterTheStartAndDismissesTheNote() {
        let spy = Spy()
        let link = ResumeResources.webPage(from: "example.org/aims")
        let note = Self.note(link: link)
        #expect(spy.runner.resume(note) == .started(link: .opened))
        #expect(spy.calls == ["start", "dismiss", "open"])
        #expect(spy.opened == [link].compactMap { $0 } && spy.dismissed == [note.id])
    }

    @Test func aNoteWithNoLinkOpensNothing() {
        let spy = Spy()
        #expect(spy.runner.resume(Self.note()) == .started(link: nil))
        #expect(spy.calls == ["start", "dismiss"])
    }

    @Test func aStartThatDidNotHappenOpensNothingAndKeepsTheNote() {
        let spy = Spy()
        spy.startResult = false
        let link = ResumeResources.webPage(from: "example.org/aims")
        #expect(spy.runner.resume(Self.note(link: link)) == .couldNotStart)
        #expect(spy.calls == ["start"], "the link is not opened and the note is not dismissed")
    }

    @Test func aLinkThatCouldNotBeOpenedIsReportedAfterTheSessionStarted() {
        let spy = Spy()
        spy.linkResult = .missing("Aims.docx")
        let link = ResumeResources.webPage(from: "example.org/aims")
        #expect(spy.runner.resume(Self.note(link: link)) == .started(link: .missing("Aims.docx")))
    }

    @Test func aDeletedProjectResumesWithNoProjectAndAnArchivedOneKeepsIt() {
        var archived = Self.grant
        archived.isArchived = true
        let deleted = ResumeNote.decide(Self.note(), projects: [], isActive: false, isOnBreak: false)
        let kept = ResumeNote.decide(Self.note(), projects: [archived], isActive: false, isOnBreak: false)
        #expect(deleted == .start(SessionRequest(goal: "Add the power analysis", projectID: nil)))
        #expect(kept == .start(SessionRequest(goal: "Add the power analysis", projectID: archived.id)),
                "finishing work on an archived project is allowed")
        #expect(ResumeNote.decide(Self.note(project: nil, link: nil), projects: [Self.grant], isActive: false, isOnBreak: false)
                == .start(SessionRequest(goal: "Add the power analysis", projectID: nil)))
    }

    @Test func aLinkOnlyNoteResumesWithItsGoal() {
        let link = ResumeResources.webPage(from: "example.org/aims")
        let note = ResumeNote(text: "", resource: link, goal: "Update Aims")
        #expect(ResumeNote.decide(note, projects: [], isActive: false, isOnBreak: false)
                == .start(SessionRequest(goal: "Update Aims", projectID: nil)))
    }
}

// MARK: - The link

struct ResumeResourceTests {
    @Test(arguments: [
        ("https://example.org/aims", "https://example.org/aims"),
        ("http://example.org", "http://example.org"),
        ("example.org/aims", "https://example.org/aims"),
        ("  www.example.org/a/b  ", "https://www.example.org/a/b"),
        ("HTTPS://Example.org/Path?q=1", "https://example.org/Path?q=1"),
    ])
    func anAddressIsHttpOrHttps(_ typed: String, _ expected: String) throws {
        let page = try #require(ResumeResources.webPage(from: typed))
        #expect(page.kind == .webPage)
        #expect(page.url == expected)
    }

    @Test(arguments: [
        "", "   ", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.org/x", "mailto:someone@example.org",
        "https://user:pass@example.org/", "two words", "https://", "x-apple.systempreferences:com.apple.preference",
        "data:text/html,hello",
    ])
    func nothingElseIsTakenAsAWebPage(_ typed: String) {
        #expect(ResumeResources.webPage(from: typed) == nil, "\(typed)")
    }

    @Test func aPageIsNamedByItsHostAndPath() throws {
        #expect(try #require(ResumeResources.webPage(from: "https://www.example.org/")).displayName == "example.org")
        #expect(try #require(ResumeResources.webPage(from: "example.org/aims/draft")).displayName == "example.org/aims/draft")
    }

    @Test func aWebPageResolvesToItsAddressAndAHandEditedOneDoesNot() throws {
        let page = try #require(ResumeResources.webPage(from: "example.org/aims"))
        #expect(ResumeResources.resolve(page) == .page(URL(string: "https://example.org/aims")!))
        let evil = WorkspaceResource(kind: .webPage, displayName: "x", url: "file:///etc/passwd")
        #expect(ResumeResources.resolve(evil) == .missing("x"))
        #expect(ResumeResources.resolve(WorkspaceResource(kind: .webPage, displayName: "none")) == .missing("none"))
    }

    @Test func aFileIsFoundByItsBookmarkEvenAfterItMoved() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Aims.docx")
        try Data("draft".utf8).write(to: file)
        let resource = try #require(ResumeResources.resource(forFile: file))
        #expect(resource.kind == .document && resource.displayName == "Aims.docx" && resource.bookmark != nil)

        guard case .file(let found, _) = ResumeResources.resolve(resource) else {
            Issue.record("expected the file"); return
        }
        #expect(found.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)

        let moved = folder.appendingPathComponent("Archive").appendingPathComponent("Aims v2.docx")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: moved)
        guard case .file(let followed, _) = ResumeResources.resolve(resource) else {
            Issue.record("expected the moved file"); return
        }
        #expect(followed.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
    }

    @Test func aFileThatIsGoneIsMissingByName() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Aims.docx")
        try Data("draft".utf8).write(to: file)
        let resource = try #require(ResumeResources.resource(forFile: file))
        try FileManager.default.removeItem(at: file)
        #expect(ResumeResources.resolve(resource) == .missing("Aims.docx"))
        #expect(ResumeResources.resolve(WorkspaceResource(kind: .folder, displayName: "Gone", path: "/nowhere/at/all")) == .missing("Gone"))
    }

    @Test func aFolderIsAFolderAndAPackageIsADocument() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sub = folder.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(ResumeResources.resource(forFile: sub)?.kind == .folder)
        let package = folder.appendingPathComponent("Notes.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(ResumeResources.resource(forFile: package)?.kind == .document, "Finder shows a package as one file")
    }

    @Test func theNotesAddNoNetworkReachAndHaveNoWebAddressInCode() {
        let names = Set(NoNetworkTests.appSources.map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["ResumeNotes.swift", "ResumeNote.swift", "ResumeResources.swift", "FocusProjects.swift",
                                      "ProjectSummary.swift", "FocusProjectViews.swift"]))
    }
}
