//
//  MigrationTests.swift
//  NidusTests
//
//  0.4 adds fields to the session, the break, the saved record, history
//  entries and categories. Files written by 0.3 must load unchanged, and a
//  new field written wrongly must lose only itself: never the running
//  session, the history around it, or the setups beside it.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct MigrationTests {
    // A session.json exactly as 0.3 wrote it (dates are seconds since 2001).
    static let legacySession = #"""
    {"session":{"plan":{"goal":"Chapter three","duration":1500,"mode":"block","apps":["com.tinyspeck.slackmacgap"],
      "websites":["youtube.com","x.com/home"],"reopensQuitApps":false,"launchApps":[],"strict":true},
      "startedAt":800000000,"phase":{"running":{"deadline":800001500}},"budget":1500,
      "snoozes":{},"quitApps":[],"blocks":{"youtube.com":2},"quitCounts":{},"foreground":{},"names":{},"seenElapsed":300},
     "lastPlan":{"goal":"Chapter three","duration":1500,"mode":"block","apps":[],"websites":["youtube.com"]},
     "pendingBreak":null}
    """#

    @Test func aSessionSavedBy03LoadsWithEveryNewFieldAtItsDefault() throws {
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(Self.legacySession.utf8))
        let plan = try #require(record.session?.plan)
        #expect(plan.goal == "Chapter three")
        #expect(plan.websites == ["youtube.com", "x.com/home"])
        #expect(plan.strict)
        #expect(plan.setupID == nil && plan.projectID == nil && plan.projectName == nil)
        #expect(plan.breakLength == nil, "nil keeps Settings' break, as 0.3 did")
        #expect(plan.breakRules == nil && plan.websiteExceptions.isEmpty && plan.resources.isEmpty)
        #expect(!plan.isContinuation && plan.sequenceStep == nil)
        #expect(record.session?.blocks == ["youtube.com": 2])
        #expect(record.sequence == nil)
    }

    @Test func aNewFieldWrittenWronglyLosesOnlyItself() throws {
        var json = Self.legacySession
        json = json.replacingOccurrences(of: #""strict":true}"#,
            with: #""strict":true,"projectID":42,"breakRules":"loud","websiteExceptions":[{"kind":"exact","address":"youtube.com/watch?v=a"},{"kind":"sideways"}],"breakLength":600}"#)
        json = json.replacingOccurrences(of: #""pendingBreak":null"#, with: #""pendingBreak":{"plan":7},"sequence":{"steps":"no"}"#)
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        let plan = try #require(record.session?.plan, "the running session survives")
        #expect(plan.websites == ["youtube.com", "x.com/home"] && plan.strict)
        #expect(plan.projectID == nil)
        #expect(plan.breakRules == nil)
        #expect(plan.websiteExceptions == [WebsiteException(kind: .exact, address: "youtube.com/watch?v=a")])
        #expect(plan.breakLength == 600)
        #expect(record.pendingBreak == nil && record.sequence == nil)
        #expect(record.lastPlan?.goal == "Chapter three")
    }

    @Test func everyNewFieldRoundTrips() throws {
        let runID = UUID()
        var plan = SessionPlan(goal: "Aims", duration: 2400, mode: .block, apps: ["a"], websites: ["youtube.com"])
        plan.setupID = UUID()
        plan.projectID = UUID()
        plan.projectName = "R01 renewal"
        plan.breakLength = 600
        plan.breakRules = BreakRules(apps: ["com.tinyspeck.slackmacgap"], websites: ["x.com"], reminder: "Water")
        plan.websiteExceptions = [WebsiteException(kind: .subtree, address: "youtube.com/@lab")]
        plan.resources = [WorkspaceResource(kind: .webPage, displayName: "Aims doc", url: "https://example.com/aims")]
        plan.isContinuation = true
        plan.sequenceStep = SequenceStepRef(runID: runID, index: 2, count: 3)
        let run = SequenceRun(id: runID, name: "Writing", steps: [.work(plan), .rest(length: 600, rules: plan.breakRules), .work(plan)],
                              index: 2, startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let record = SessionRecord(lastPlan: plan,
                                   pendingBreak: BreakState(plan: plan, endsAt: Date(timeIntervalSinceReferenceDate: 800_000_600),
                                                            length: 600, rules: plan.breakRules),
                                   sequence: run)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test func theEngineSavesAndRestoresTheSequence() throws {
        let store = MemoryStore()
        let run = SequenceRun(name: "Writing", steps: [.rest(length: 60, rules: nil)], startedAt: Date())
        store.record = SessionRecord(sequence: run)
        let engine = SessionEngine(store: store)
        engine.restore()
        #expect(engine.sequence == run)
        engine.checkpoint()
        engine.startBreak(plan: SessionPlan(goal: "", duration: 60, mode: .block, apps: [], websites: []), length: 60)
        #expect(store.record?.sequence == run, "a save keeps the sequence it restored")
    }

    // MARK: History

    static func legacyEntry(id: String = UUID().uuidString, goal: String = "Aims", extra: String = "") -> String {
        #"{"id":"\#(id)","start":800000000,"end":800001500,"focused":1500,"planned":1500,"outcome":"completed","goal":"\#(goal)","blocks":{},"quits":{},"foreground":{},"names":{}\#(extra)}"#
    }

    @Test func historyFrom03LoadsAndABadEntryIsDroppedAlone() throws {
        let good = Self.legacyEntry(goal: "Kept")
        let badField = Self.legacyEntry(goal: "Also kept", extra: #","projectID":"not-a-uuid","sequenceStep":5"#)
        let broken = #"{"id":"x","goal":"Missing everything"}"#
        let data = Data(#"{"version":1,"sessions":[\#(good),\#(broken),\#(badField)]}"#.utf8)
        let file = try JSONDecoder().decode(FocusHistory.File.self, from: data)
        #expect(file.sessions.map(\.goal) == ["Kept", "Also kept"])
        #expect(file.sessions[1].projectID == nil)
    }

    @Test func anUnreadableHistoryFileIsSetAsideNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        try Data("{ this is not json".utf8).write(to: url)
        let history = FocusHistory(url: url)
        #expect(history.sessions.isEmpty)
        history.append(SessionEntry(start: Date(), end: Date(), focused: 600, planned: nil, outcome: .completed))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let aside = try #require(names.first { $0.hasPrefix("history.unreadable-") })
        #expect(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8) == "{ this is not json")
    }

    @Test func anEntryCarriesItsPlansProjectSetupAndStep() throws {
        var plan = SessionPlan(goal: "Aims", duration: 1500, mode: .block, apps: [], websites: [])
        plan.projectID = UUID()
        plan.projectName = "Grant"
        plan.setupID = UUID()
        plan.sequenceStep = SequenceStepRef(runID: UUID(), index: 0, count: 3)
        var state = SessionState(plan: plan, startedAt: Date(), phase: .running(deadline: Date()), budget: 1500)
        state.focusedTime = 1500
        state.endedAt = Date()
        let entry = try #require(SessionEntry(ended: state, outcome: .completed))
        #expect(entry.projectID == plan.projectID && entry.projectName == "Grant")
        #expect(entry.setupID == plan.setupID && entry.sequenceStep == plan.sequenceStep)
        let back = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(entry))
        #expect(back == entry)
    }

    // MARK: Saved lists

    @Test func oneSetupThatDoesNotDecodeLeavesTheOthers() throws {
        let data = Data(#"[{"id":"\#(UUID().uuidString)","name":"Writing"},{"name":"No id"},{"id":"\#(UUID().uuidString)","name":"Deep work","minutes":90}]"#.utf8)
        let setups = try #require(LossyJSON.list(FocusSetup.self, from: data))
        #expect(setups.map(\.name) == ["Writing", "Deep work"])
        #expect(LossyJSON.list(FocusSetup.self, from: Data("{}".utf8)) == nil, "not a list: the caller keeps its default")
    }

    @Test func aCategoryFrom03LoadsWithNoExceptions() throws {
        let legacy = #"{"id":"video","name":"Video","symbol":"play.rectangle","apps":[],"websites":["youtube.com"]}"#
        let category = try JSONDecoder().decode(FocusCategory.self, from: Data(legacy.utf8))
        #expect(category.websites == ["youtube.com"] && category.websiteExceptions.isEmpty)
        let withOneBad = #"{"id":"video","name":"Video","symbol":"play.rectangle","apps":[],"websites":["youtube.com"],"websiteExceptions":[{"kind":"exact","address":"youtube.com/watch?v=a"},12]}"#
        #expect(try JSONDecoder().decode(FocusCategory.self, from: Data(withOneBad.utf8)).websiteExceptions.count == 1)
    }

    @Test func breakRulesBoundTheReminderAndKnowWhenTheyAreEmpty() {
        #expect(BreakRules().isUnrestricted)
        #expect(BreakRules(reminder: "   ").displayReminder == nil)
        #expect(BreakRules(reminder: String(repeating: "a", count: 500)).displayReminder?.count == BreakRules.reminderLimit)
        #expect(!BreakRules(websites: ["x.com"]).isUnrestricted)
    }
}
