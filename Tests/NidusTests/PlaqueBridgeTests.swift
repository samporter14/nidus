//
//  PlaqueBridgeTests.swift
//  NidusTests
//
//  What Nidus tells Plaque: the snapshot's values, what it leaves out, when
//  it is written, and that turning it off removes it. The golden file in
//  docs/ is the contract both apps test against.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct PlaqueBridgeTests {
    static let iso = ISO8601DateFormatter()
    static func at(_ text: String) -> Date { iso.date(from: text)! }

    /// The state docs/plaque-focus-v1.example.json describes.
    static var goldenInput: PlaqueFocusSnapshot.Input {
        .init(phase: .focusing(endsAt: at("2026-10-16T14:25:00Z")),
              sessionID: "6D0C0F4E-2E35-4C2B-9C8E-0A1B2C3D4E5F", startedAt: at("2026-10-16T13:45:00Z"),
              next: .init(kind: .break, startsAt: at("2026-10-16T14:25:00Z"), minutes: 10),
              sequence: .init(name: "Grant morning", step: 1, count: 3),
              goal: "Update Specific Aims", project: "R01 renewal")
    }

    static func json(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func theGoldenStateEncodesToTheGoldenFile() throws {
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/plaque-focus-v1.example.json")
        let snapshot = PlaqueFocusSnapshot.make(Self.goldenInput, revision: 42, now: Self.at("2026-10-16T14:02:00Z"),
                                                sharesText: true)
        let data = try #require(snapshot.encoded())
        #expect(try Self.json(data) == Self.json(Data(contentsOf: golden)))
        #expect(PlaqueFocusSnapshot.decoded(from: try Data(contentsOf: golden)) == snapshot)
    }

    @Test func withoutTextSharingNoWordsTheyTypedGoIn() throws {
        let snapshot = PlaqueFocusSnapshot.make(Self.goldenInput, revision: 1, now: Self.at("2026-10-16T14:02:00Z"),
                                                sharesText: false)
        let data = try #require(snapshot.encoded())
        let text = String(decoding: data, as: UTF8.self)
        #expect(try Self.json(data)["text"] == nil)
        #expect(!text.contains("Specific Aims") && !text.contains("R01") && !text.contains("Grant morning"))
        #expect(snapshot.sequence == .init(name: nil, step: 1, count: 3), "where it is in the run, without its name")
    }

    @Test func textIsTrimmedAndBoundedAndTheFileStaysSmall() throws {
        var input = Self.goldenInput
        input.goal = "  " + String(repeating: "g", count: 500) + "  "
        input.project = String(repeating: "p", count: 500)
        input.sequence?.name = String(repeating: "s", count: 500)
        let snapshot = PlaqueFocusSnapshot.make(input, revision: 1, now: Date(), sharesText: true)
        #expect(snapshot.text?.goal?.count == PlaqueFocusSnapshot.goalLimit)
        #expect(snapshot.text?.project?.count == PlaqueFocusSnapshot.projectLimit)
        #expect(snapshot.sequence?.name?.count == PlaqueFocusSnapshot.sequenceNameLimit)
        #expect((snapshot.encoded()?.count ?? .max) <= PlaqueFocusSnapshot.byteLimit)
        input.goal = "   "
        input.project = nil
        #expect(PlaqueFocusSnapshot.make(input, revision: 1, now: Date(), sharesText: true).text == nil)
    }

    @Test func eachStateSaysWhatItShould() {
        let now = Self.at("2026-10-16T14:02:00Z")
        let paused = PlaqueFocusSnapshot.make(.init(phase: .paused(remaining: 600.2), sessionID: "a", startedAt: now),
                                              revision: 1, now: now, sharesText: false)
        #expect(paused.state == .paused && paused.endsAt == nil && paused.pausedRemainingSeconds == 601)

        let onBreak = PlaqueFocusSnapshot.make(.init(phase: .onBreak(endsAt: now.addingTimeInterval(300)), sessionID: "b",
                                                     startedAt: now, next: .init(kind: .block, startsAt: now.addingTimeInterval(300), minutes: 25)),
                                               revision: 1, now: now, sharesText: false)
        #expect(onBreak.state == .break && onBreak.endsAt == now.addingTimeInterval(300) && onBreak.next?.kind == .block)

        let openEnded = PlaqueFocusSnapshot.make(.init(phase: .focusing(endsAt: nil), sessionID: "c", startedAt: now),
                                                 revision: 1, now: now, sharesText: false)
        #expect(openEnded.openEnded && openEnded.endsAt == nil)

        let finished = PlaqueFocusSnapshot.make(.init(phase: .finished, sessionID: "d", startedAt: now,
                                                      next: .init(kind: .break), goal: "Aims", nextStep: "Draft Aim 2"),
                                                revision: 1, now: now, sharesText: true)
        #expect(finished.state == .finished && finished.next == nil && finished.text?.nextStep == "Draft Aim 2")
        let focusingStep = PlaqueFocusSnapshot.make(.init(phase: .focusing(endsAt: now), sessionID: "e", startedAt: now,
                                                          goal: "Aims", nextStep: "Not yet"),
                                                    revision: 1, now: now, sharesText: true)
        #expect(focusingStep.text?.nextStep == nil, "a next step is shown only once the session is done")

        for phase in [PlaqueFocusSnapshot.Input.Phase.idle, .offline] {
            let resting = PlaqueFocusSnapshot.make(.init(phase: phase, sessionID: "f", startedAt: now, goal: "Aims"),
                                                   revision: 1, now: now, sharesText: true)
            #expect(resting.session == nil && resting.text == nil && resting.next == nil)
            #expect(resting.expiresAt == now.addingTimeInterval(PlaqueFocusSnapshot.restingLifetime))
        }
        #expect(paused.expiresAt == now.addingTimeInterval(PlaqueFocusSnapshot.liveLifetime))
    }

    @Test func aSessionsIDIsStableAndItsOwn() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123)
        #expect(PlaqueFocusSnapshot.sessionID(startedAt: start) == PlaqueFocusSnapshot.sessionID(startedAt: start))
        #expect(PlaqueFocusSnapshot.sessionID(startedAt: start) != PlaqueFocusSnapshot.sessionID(startedAt: start.addingTimeInterval(1)))
        #expect(UUID(uuidString: PlaqueFocusSnapshot.sessionID(startedAt: start)) != nil)
    }

    // MARK: Writing

    final class Probe {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var notices = 0
        var revision = 0
    }

    func bridge(in folder: URL, _ probe: Probe) -> PlaqueBridge {
        PlaqueBridge(directory: folder, now: { probe.now }, notify: { probe.notices += 1 },
                     loadRevision: { probe.revision }, saveRevision: { probe.revision = $0 })
    }

    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-plaque-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func offWritesNothingAndTurningOffRemovesTheFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = Probe()
        let bridge = bridge(in: folder, probe)
        bridge.publish(Self.goldenInput, enabled: false, sharesText: true)
        #expect(!FileManager.default.fileExists(atPath: bridge.fileURL.path) && probe.notices == 0)

        bridge.publish(Self.goldenInput, enabled: true, sharesText: true)
        #expect(FileManager.default.fileExists(atPath: bridge.fileURL.path) && probe.notices == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [PlaqueBridge.fileName],
                "only its own file: focus.json is the model's, and no temporary file is left")

        bridge.publish(Self.goldenInput, enabled: false, sharesText: true)
        #expect(!FileManager.default.fileExists(atPath: bridge.fileURL.path) && probe.notices == 2)
        bridge.publish(Self.goldenInput, enabled: false, sharesText: true)
        #expect(probe.notices == 2, "already gone: no second notice")
    }

    @Test func aChangeIsWrittenAtOnceAndTheSameStateOnlyOnTheHeartbeat() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = Probe()
        let bridge = bridge(in: folder, probe)
        var input = PlaqueFocusSnapshot.Input(phase: .focusing(endsAt: probe.now.addingTimeInterval(1500)),
                                              sessionID: "s", startedAt: probe.now)
        bridge.publish(input, enabled: true, sharesText: false)
        #expect(probe.revision == 1)
        for _ in 0..<60 {
            probe.now += 1
            bridge.publish(input, enabled: true, sharesText: false)
        }
        #expect(probe.revision == 1, "a minute of the same state is one write")
        probe.now += PlaqueFocusSnapshot.heartbeat
        bridge.publish(input, enabled: true, sharesText: false)
        #expect(probe.revision == 2, "the heartbeat writes it again, with a fresh expiry")
        input.phase = .paused(remaining: 900)
        bridge.publish(input, enabled: true, sharesText: false)
        #expect(probe.revision == 3)
        let written = try #require(PlaqueFocusSnapshot.decoded(from: Data(contentsOf: bridge.fileURL)))
        #expect(written.state == .paused && written.revision == 3)
        #expect(written.expiresAt == written.updatedAt.addingTimeInterval(PlaqueFocusSnapshot.liveLifetime))

        bridge.publish(.init(phase: .idle), enabled: true, sharesText: false)
        probe.now += 3 * PlaqueFocusSnapshot.heartbeat
        bridge.publish(.init(phase: .idle), enabled: true, sharesText: false)
        #expect(probe.revision == 4, "idle needs no heartbeat: it can't be mistaken for focus")
    }

    @Test func revisionsKeepRisingAcrossARelaunch() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = Probe()
        bridge(in: folder, probe).publish(Self.goldenInput, enabled: true, sharesText: false)
        let second = bridge(in: folder, probe)
        second.publish(.init(phase: .offline), enabled: true, sharesText: false)
        #expect(probe.revision == 2)
        #expect(PlaqueFocusSnapshot.decoded(from: try Data(contentsOf: second.fileURL))?.state == .offline)
    }

    @Test func finishedLastsAWhileThenGoes() {
        let probe = Probe()
        let bridge = PlaqueBridge(directory: FileManager.default.temporaryDirectory, now: { probe.now })
        bridge.noteFinished(.init(sessionID: "s", startedAt: probe.now, at: probe.now, goal: "Aims"))
        #expect(bridge.recentFinish(at: probe.now.addingTimeInterval(60)) != nil)
        #expect(bridge.recentFinish(at: probe.now.addingTimeInterval(PlaqueFocusSnapshot.finishedLinger)) == nil)
    }

    // MARK: What comes next

    static func session(duration: TimeInterval? = 1500, breakLength: TimeInterval? = nil) -> SessionState {
        var plan = SessionPlan(goal: "Aims", duration: duration, mode: .block, apps: [], websites: [])
        plan.breakLength = breakLength
        return SessionState(plan: plan, startedAt: Date(), phase: .running(deadline: Date()), budget: duration ?? 0)
    }

    @Test func theNextThingFollowsTheSequenceOrTheBreak() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let work = SessionPlan(goal: "Figures", duration: 25 * 60, mode: .block, apps: [], websites: [])
        let run = SequenceRun(name: "Grant", steps: [.work(work), .rest(length: 600, rules: nil), .work(work)], startedAt: end)
        #expect(NidusModel.plaqueNext(after: Self.session(), sequence: run, endsAt: end, settingsBreak: 0, fixedEnd: false)
                == .init(kind: .break, startsAt: end, minutes: 10))
        var last = run
        last.index = 2
        #expect(NidusModel.plaqueNext(after: Self.session(), sequence: last, endsAt: end, settingsBreak: 300, fixedEnd: false)?.kind == .finish)
        var direct = SequenceRun(name: "Two", steps: [.work(work), .work(work)], startedAt: end)
        direct.index = 0
        #expect(NidusModel.plaqueNext(after: Self.session(), sequence: direct, endsAt: end, settingsBreak: 0, fixedEnd: false)
                == .init(kind: .block, startsAt: end, minutes: 25))

        #expect(NidusModel.plaqueNext(after: Self.session(), sequence: nil, endsAt: end, settingsBreak: 300, fixedEnd: false)?.minutes == 5)
        #expect(NidusModel.plaqueNext(after: Self.session(breakLength: 0), sequence: nil, endsAt: end, settingsBreak: 300, fixedEnd: false) == nil,
                "a plan's own 0 means no break, whatever Settings says")
        #expect(NidusModel.plaqueNext(after: Self.session(), sequence: nil, endsAt: end, settingsBreak: 300, fixedEnd: true) == nil)
        #expect(NidusModel.plaqueNext(after: Self.session(duration: nil), sequence: nil, endsAt: nil, settingsBreak: 300, fixedEnd: false) == nil)
    }

    @Test func aSequencesStepCountsWorkBlocksOnly() {
        let work = SessionPlan(goal: "", duration: 60, mode: .block, apps: [], websites: [])
        var run = SequenceRun(name: "Grant", steps: [.work(work), .rest(length: 60, rules: nil), .work(work), .work(work)],
                              startedAt: Date())
        #expect(NidusModel.plaqueSequence(run) == .init(name: "Grant", step: 1, count: 3))
        run.index = 1
        #expect(NidusModel.plaqueSequence(run)?.step == 2, "on the break: the block that comes next")
        run.index = 3
        #expect(NidusModel.plaqueSequence(run)?.step == 3)
        #expect(NidusModel.plaqueSequence(nil) == nil)
    }
}
