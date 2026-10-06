//
//  FocusCommandTests.swift
//  NidusTests
//
//  The automation commands (FocusOutside.swift) and the JSON command
//  (FocusCommands.swift), run against a fake session: what an assistant, a
//  Shortcut or a link gets back, and what it changes, without blocking a
//  thing.
//

import Foundation
import Testing
@testable import Nidus

/// A session in memory: starts, ends and adds time the way the engine does
/// (24 hours at most), and records what it was asked.
@MainActor
final class FakeFocusTarget: FocusCommandTarget {
    var state: FocusStatus.State = .idle
    var isOpenEnded = false
    var isStrict = false
    var secondsLeft: TimeInterval = 0
    var setups: [FocusSetup] = []
    var categories: [FocusCategory] = [
        FocusCategory(id: "social", name: "Social", symbol: "person.2", apps: [], websites: ["x.com"]),
        FocusCategory(id: "video", name: "Video", symbol: "play.rectangle", apps: [], websites: ["youtube.com"]),
        FocusCategory(id: "empty", name: "Empty", symbol: "square", apps: [], websites: []),
    ]
    private(set) var started: [SessionRequest] = []
    private(set) var extendCalls = 0
    private(set) var endCalls = 0

    var commandStatus: FocusStatus {
        FocusStatus(state: state, isOpenEnded: isOpenEnded, isStrict: isStrict,
                    isBlocking: state == .running, remaining: secondsLeft)
    }

    func startFromOutside(_ request: SessionRequest) -> OutsideStart {
        guard state == .idle else { return .busy }
        let ids = request.categoryIDs ?? ["social"]
        let chosen = categories.filter { ids.contains($0.id) }
        guard request.mode == .allow || !chosen.allSatisfy(\.isEmpty) else { return .nothingToBlock }
        started.append(request)
        state = .running
        let minutes = request.minutes ?? 25
        isOpenEnded = minutes == 0
        isStrict = request.strict ?? false
        secondsLeft = TimeInterval(minutes * 60)
        return .started
    }

    func endFromOutside() -> OutsideEnd {
        endCalls += 1
        let outcome = OutsideEnd(isActive: state == .running || state == .paused, isStrict: isStrict, isOnBreak: state == .onBreak)
        if outcome == .endsSession || outcome == .endsBreak { state = .idle }
        return outcome
    }

    func extendSession(by seconds: TimeInterval) {
        extendCalls += 1
        // The engine extends open-ended sessions too, against the cap; the
        // command must refuse those before it gets here.
        secondsLeft = min(secondsLeft + seconds, SessionPlan.maximumDuration)
    }

    func run(_ json: String, ledger: FocusCommandLedger) -> [String: Any] {
        let text = FocusCommands.respond(to: json, target: self, ledger: ledger)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}

private func outcome(_ answer: [String: Any]) -> String? { answer["outcome"] as? String }
private func status(_ answer: [String: Any]) -> [String: Any] { answer["status"] as? [String: Any] ?? [:] }

// MARK: - Adding time

@MainActor
struct AddTimeTests {
    @Test func addsToATimedSessionAndSaysHowMuch() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 18 * 60
        #expect(target.addTimeFromOutside(minutes: 15) == .added(minutes: 15))
        #expect(target.commandStatus.minutesLeft == 33)
    }

    @Test func aPausedSessionTakesTimeToo() {
        let target = FakeFocusTarget()
        target.state = .paused
        target.secondsLeft = 600
        #expect(target.addTimeFromOutside(minutes: 5) == .added(minutes: 5))
    }

    @Test func theCapIsReportedNotHidden() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = SessionPlan.maximumDuration - 5 * 60
        #expect(target.addTimeFromOutside(minutes: 15) == .added(minutes: 5), "only what fit")
        #expect(target.addTimeFromOutside(minutes: 15) == .atMaximum, "nothing fits")
        #expect(target.extendCalls == 1)
    }

    @Test func lessThanAMinuteOfRoomAddsNothing() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = SessionPlan.maximumDuration - 20
        #expect(target.addTimeFromOutside(minutes: 1) == .atMaximum)
        #expect(target.extendCalls == 0, "no part-minute it couldn't report")
    }

    @Test func nothingIsAddedWhereThereIsNoEndToMove() {
        let target = FakeFocusTarget()
        #expect(target.addTimeFromOutside(minutes: 15) == .nothingRunning)
        target.state = .onBreak
        target.secondsLeft = 300
        #expect(target.addTimeFromOutside(minutes: 15) == .onBreak)
        target.state = .running
        target.isOpenEnded = true
        #expect(target.addTimeFromOutside(minutes: 15) == .openEnded)
        #expect(target.extendCalls == 0, "refused before the engine is asked")
    }

    @Test(arguments: [0, -5, 1441])
    func minutesOutsideOneToADayAreRefused(_ minutes: Int) {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 600
        #expect(target.addTimeFromOutside(minutes: minutes) == .invalidMinutes)
        #expect(target.extendCalls == 0)
    }
}

// MARK: - Starting from a setup

@MainActor
struct OutsideStartTests {
    private let writing = FocusSetup(name: "Writing", symbol: "pencil", minutes: 45, categoryIDs: ["social", "video"],
                                     goal: "Draft the next section")
    private let deep = FocusSetup(name: "Deep work", minutes: 90, categoryIDs: ["social"], mode: .allow, strict: true)

    private func target() -> FakeFocusTarget {
        let target = FakeFocusTarget()
        target.setups = [writing, deep]
        return target
    }

    @Test func aSetupByIdOrNameGivesItsChoices() throws {
        for key in [writing.id.uuidString, writing.id.uuidString.lowercased(), "writing", " Writing "] {
            let resolved = try target().outsideRequest(NidusLink.Start(preset: key)).get()
            #expect(resolved.setup == writing)
            #expect(resolved.request.minutes == 45 && resolved.request.categoryIDs == ["social", "video"])
            #expect(resolved.request.goal == "Draft the next section")
        }
    }

    @Test func whatIsAskedForWinsOverTheSetup() throws {
        let ask = NidusLink.Start(goal: "Chapter three", minutes: 30, categories: ["video"], mode: .block, preset: "Writing")
        let request = try target().outsideRequest(ask).get().request
        #expect(request.goal == "Chapter three" && request.minutes == 30)
        #expect(request.categoryIDs == ["video"] && request.mode == .block)
    }

    @Test func strictOnlyEverTurnsOn() throws {
        let fromStrict = try target().outsideRequest(NidusLink.Start(strict: false, preset: "Deep work")).get().request
        #expect(fromStrict.strict == true, "a strict setup stays strict")
        let made = try target().outsideRequest(NidusLink.Start(strict: true, preset: "Writing")).get().request
        #expect(made.strict == true)
        #expect(try target().outsideRequest(NidusLink.Start(strict: false)).get().request.strict == nil,
                "no setup and no strict: Settings decides")
    }

    @Test func aMissingSetupIsAnErrorNotTheDefaults() {
        #expect(throws: OutsideStartProblem.setupNotFound) { try target().outsideRequest(NidusLink.Start(preset: "Reading")).get() }
        #expect(throws: OutsideStartProblem.setupNotFound) { try target().outsideRequest(NidusLink.Start(preset: UUID().uuidString)).get() }
    }

    @Test func twoSetupsWithOneNameNeedTheId() throws {
        let target = target()
        let twin = FocusSetup(name: "writing", minutes: 25, categoryIDs: ["video"])
        target.setups.append(twin)
        #expect(throws: OutsideStartProblem.setupAmbiguous) { try target.outsideRequest(NidusLink.Start(preset: "Writing")).get() }
        #expect(try target.outsideRequest(NidusLink.Start(preset: twin.id.uuidString)).get().setup == twin)
    }

    @Test func namedCategoriesThatDontExistStartNothing() {
        #expect(throws: OutsideStartProblem.noMatchingCategory) {
            try target().outsideRequest(NidusLink.Start(categories: ["Gaming"])).get()
        }
    }

    @Test func aLaunchLinkNamesTheSetupByIdAndNothingElse() {
        let link = writing.launchLink
        #expect(link.absoluteString == "nidus://start?preset=\(writing.id.uuidString)")
        guard case .start(let start) = NidusLink(url: link) else { Issue.record("not a start link"); return }
        #expect(start.preset == writing.id.uuidString && start.goal == nil)
    }
}

// MARK: - The JSON command

@MainActor
struct FocusCommandJSONTests {
    @Test func statusChangesNothing() {
        let target = FakeFocusTarget()
        target.state = .paused
        target.secondsLeft = 18 * 60
        let answer = target.run(#"{"version":1,"action":"status"}"#, ledger: FocusCommandLedger())
        #expect(answer["ok"] as? Bool == true)
        #expect(status(answer)["state"] as? String == "paused")
        #expect(status(answer)["minutesLeft"] as? Int == 18)
        #expect(status(answer)["observedAt"] is String)
        #expect(target.started.isEmpty && target.endCalls == 0 && target.extendCalls == 0)
    }

    @Test func aStartSaysWhatStartedAndAsksNoPermissionFromAfar() {
        let target = FakeFocusTarget()
        target.setups = [FocusSetup(name: "Writing", minutes: 45, categoryIDs: ["social"])]
        let answer = target.run(#"{"action":"start","setup":"Writing"}"#, ledger: FocusCommandLedger())
        #expect(outcome(answer) == "started")
        #expect(answer["message"] as? String == "Started Writing for 45 minutes.")
        #expect(target.started.first?.asksBrowserAccess == false)
        #expect(status(answer)["state"] as? String == "running")
    }

    @Test func aStartNeverReplacesWhatIsOn() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 600
        let answer = target.run(#"{"action":"start","minutes":45}"#, ledger: FocusCommandLedger())
        #expect(outcome(answer) == "busy" && answer["ok"] as? Bool == false)
        #expect(status(answer)["minutesLeft"] as? Int == 10, "the session that was on, untouched")
        #expect(target.started.isEmpty && target.endCalls == 0)
    }

    @Test func anUnknownSetupStartsNothing() {
        let target = FakeFocusTarget()
        let answer = target.run(#"{"action":"start","setup":"Reading"}"#, ledger: FocusCommandLedger())
        #expect(outcome(answer) == "setupNotFound")
        #expect(target.started.isEmpty)
    }

    @Test func aGoalIsKeptToOneLine() {
        let target = FakeFocusTarget()
        _ = target.run(#"{"action":"start","goal":"Write\nthe paper  "}"#, ledger: FocusCommandLedger())
        #expect(target.started.first?.goal == "Write the paper")
    }

    @Test func badMinutesAndModesAreRefused() {
        let target = FakeFocusTarget()
        #expect(outcome(target.run(#"{"action":"start","minutes":1441}"#, ledger: FocusCommandLedger())) == "invalidMinutes")
        #expect(outcome(target.run(#"{"action":"start","mode":"maybe"}"#, ledger: FocusCommandLedger())) == "invalidMode")
        #expect(outcome(target.run(#"{"action":"addTime"}"#, ledger: FocusCommandLedger())) == "invalidMinutes",
                "an add with no minutes is a mistake, whatever is on")
        #expect(target.started.isEmpty)
    }

    @Test func aStrictSessionIsNotEndedFromOutside() {
        let target = FakeFocusTarget()
        target.state = .running
        target.isStrict = true
        target.secondsLeft = 600
        let answer = target.run(#"{"action":"end"}"#, ledger: FocusCommandLedger())
        #expect(outcome(answer) == "refusedStrict")
        #expect(target.state == .running)
    }

    @Test func aRetriedAddIsAnsweredNotDoneTwice() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 18 * 60
        let ledger = FocusCommandLedger()
        let request = #"{"action":"addTime","minutes":15,"id":"a1"}"#
        let first = target.run(request, ledger: ledger)
        let again = target.run(request, ledger: ledger)
        #expect(outcome(first) == "added" && first["addedMinutes"] as? Int == 15)
        #expect(first["message"] as? String == "Added 15 minutes. You have 33 minutes left.")
        #expect(again["duplicate"] as? Bool == true && outcome(again) == "added")
        #expect(target.extendCalls == 1)
        #expect(target.commandStatus.minutesLeft == 33)
        // A new id is a new request.
        _ = target.run(#"{"action":"addTime","minutes":15,"id":"a2"}"#, ledger: ledger)
        #expect(target.commandStatus.minutesLeft == 48)
    }

    @Test func setupsAreListedWithTheirIds() {
        let target = FakeFocusTarget()
        let writing = FocusSetup(name: "Writing", minutes: 45, categoryIDs: ["social", "video"])
        target.setups = [writing]
        let answer = target.run(#"{"action":"setups"}"#, ledger: FocusCommandLedger())
        let listed = answer["setups"] as? [[String: Any]] ?? []
        #expect(listed.first?["id"] as? String == writing.id.uuidString)
        #expect(listed.first?["name"] as? String == "Writing")
        #expect(target.started.isEmpty)
    }

    @Test func whatItCantReadStillGetsJSONBack() {
        let target = FakeFocusTarget()
        #expect(outcome(target.run("not json", ledger: FocusCommandLedger())) == "invalidRequest")
        #expect(outcome(target.run(#"{"version":2,"action":"status"}"#, ledger: FocusCommandLedger())) == "unsupportedVersion")
        #expect(outcome(target.run(#"{"action":"toggle"}"#, ledger: FocusCommandLedger())) == "unknownAction",
                "no toggle here: an assistant says what it means")
        let away = FocusCommands.respond(to: #"{"action":"status"}"#, target: nil, ledger: FocusCommandLedger())
        #expect(away.contains(#""outcome":"notReady""#))
    }

    @Test func aRefusalIsntRememberedSoARetryRunsAgain() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 600
        let ledger = FocusCommandLedger()
        let request = #"{"action":"start","minutes":45,"id":"s1"}"#
        #expect(outcome(target.run(request, ledger: ledger)) == "busy")
        target.state = .idle
        let retry = target.run(request, ledger: ledger)
        #expect(outcome(retry) == "started" && retry["duplicate"] == nil)
        #expect(target.started.count == 1)
    }

    @Test func anIdReusedForSomethingElseDoesNothing() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 600
        let ledger = FocusCommandLedger()
        _ = target.run(#"{"action":"addTime","minutes":5,"id":"same"}"#, ledger: ledger)
        let other = target.run(#"{"action":"addTime","minutes":30,"id":"same"}"#, ledger: ledger)
        #expect(outcome(other) == "idReused" && other["ok"] as? Bool == false)
        #expect(target.extendCalls == 1)
    }

    @Test func aBlankIdIsNoId() {
        let target = FakeFocusTarget()
        target.state = .running
        target.secondsLeft = 600
        let ledger = FocusCommandLedger()
        _ = target.run(#"{"action":"addTime","minutes":5,"id":" "}"#, ledger: ledger)
        _ = target.run(#"{"action":"addTime","minutes":5,"id":" "}"#, ledger: ledger)
        #expect(target.extendCalls == 2, "nothing to match a retry by")
    }

    @Test func rememberedAnswersExpireAndAreBounded() {
        let ledger = FocusCommandLedger()
        let answer = FocusCommandResponse(ok: true, action: "end", outcome: "ended", message: "")
        let request = FocusCommandRequest(action: "end", id: "x")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        ledger.remember(answer, to: request, key: "k", now: start)
        #expect(ledger.recall(request, key: "k", now: start.addingTimeInterval(60)) == .answered(answer))
        #expect(ledger.recall(request, key: "k", now: start.addingTimeInterval(FocusCommandLedger.lifetime + 1)) == .new)
        for index in 0..<(FocusCommandLedger.capacity + 5) {
            ledger.remember(answer, to: request, key: "k\(index)", now: start)
        }
        #expect(ledger.recall(request, key: "k0", now: start) == .new)
        #expect(ledger.recall(request, key: "k\(FocusCommandLedger.capacity + 4)", now: start) != .new)
        let refused = FocusCommandResponse(ok: false, action: "end", outcome: "refusedStrict", message: "")
        ledger.remember(refused, to: request, key: "no", now: start)
        #expect(ledger.recall(request, key: "no", now: start) == .new, "a refusal isn't kept")
    }

    @Test func aBreakSaysItsOwnMinutesNotTheSessions() {
        let target = FakeFocusTarget()
        target.state = .onBreak
        target.secondsLeft = 240
        let now = status(target.run(#"{"action":"status"}"#, ledger: FocusCommandLedger()))
        #expect(now["state"] as? String == "break")
        #expect(now["minutesLeft"] == nil, "as 0.2.0: a break isn't focus time")
        #expect(now["breakMinutesLeft"] as? Int == 4)
        #expect(now["isOn"] as? Bool == false)
    }

    @Test func blanksCountAsLeftOut() {
        let target = FakeFocusTarget()
        target.setups = [FocusSetup(name: "Writing", minutes: 45, categoryIDs: ["video"], goal: "Draft")]
        _ = target.run(#"{"action":"start","setup":"Writing","goal":"  ","categories":[]}"#, ledger: FocusCommandLedger())
        #expect(target.started.first?.goal == "Draft", "a blank goal doesn't wipe the setup's")
        #expect(target.started.first?.categoryIDs == ["video"], "no categories means the setup's")
        target.state = .idle
        let unnamed = FocusSetup(name: "", minutes: 10, categoryIDs: ["social"])
        target.setups.append(unnamed)
        _ = target.run(#"{"action":"start","setup":" "}"#, ledger: FocusCommandLedger())
        #expect(target.started.last?.minutes == nil, "a blank setup is no setup, not the unnamed one")
    }
}

struct SpokenMinutesTests {
    @Test func minutesReadAsWords() {
        #expect(FocusFormat.minutes(1) == "1 minute")
        #expect(FocusFormat.minutes(45) == "45 minutes")
        #expect(FocusFormat.minutes(60) == "1 hour")
        #expect(FocusFormat.minutes(90) == "1 hour 30 minutes")
        #expect(FocusFormat.minutes(121) == "2 hours 1 minute")
    }
}
