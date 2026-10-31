//
//  StrictGuardTests.swift
//  NidusTests
//
//  A strict session refuses to quit and is kept alive by launchd's watcher;
//  both decide from the same reading of session.json. Logging out and an
//  update always get through, and nothing is kept alive on a guess.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct StrictGuardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(strict: Bool, phase: SessionState.Phase, ended: Bool = false) -> SessionState {
        var plan = SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: ["youtube.com"])
        plan.strict = strict
        var state = SessionState(plan: plan, startedAt: now.addingTimeInterval(-60), phase: phase, budget: 25 * 60)
        if ended { state.endedAt = now }
        return state
    }

    @Test func aRunningStrictSessionIsLive() {
        #expect(StrictGuard.isLiveStrict(session(strict: true, phase: .running(deadline: now.addingTimeInterval(60))), now: now))
    }

    @Test func nonStrictPastDeadlineEndedOrIdleIsNotLive() {
        #expect(!StrictGuard.isLiveStrict(nil, now: now))
        #expect(!StrictGuard.isLiveStrict(session(strict: false, phase: .running(deadline: now.addingTimeInterval(60))), now: now))
        #expect(!StrictGuard.isLiveStrict(session(strict: true, phase: .running(deadline: now.addingTimeInterval(-1))), now: now))
        #expect(!StrictGuard.isLiveStrict(session(strict: true, phase: .running(deadline: now.addingTimeInterval(60)), ended: true), now: now))
    }

    @Test func aStrictSessionPausedBySleepStaysLive() {
        #expect(StrictGuard.isLiveStrict(session(strict: true, phase: .paused(remaining: 60, bySleep: true)), now: now))
        #expect(!StrictGuard.isLiveStrict(session(strict: true, phase: .paused(remaining: 60, bySleep: false)), now: now))
    }

    @Test func theSavedFileIsReadTheSameWay() throws {
        let live = SessionRecord(session: session(strict: true, phase: .running(deadline: now.addingTimeInterval(60))))
        #expect(StrictGuard.isLiveStrict(record: try JSONEncoder().encode(live), now: now))
        #expect(!StrictGuard.isLiveStrict(record: SessionRecord().encodedForTest, now: now))
        // Unreadable or missing: never kept alive on a guess.
        #expect(!StrictGuard.isLiveStrict(record: Data("not json".utf8), now: now))
        #expect(!StrictGuard.isLiveStrict(record: nil, now: now))
    }

    @Test func terminationIsVetoedOnlyDuringAStrictSession() {
        #expect(StrictGuard.vetoesQuit(liveStrict: true, systemIsEnding: false, updatePermitted: false))
        #expect(!StrictGuard.vetoesQuit(liveStrict: false, systemIsEnding: false, updatePermitted: false))
        #expect(!StrictGuard.vetoesQuit(liveStrict: true, systemIsEnding: true, updatePermitted: false), "logout and shutdown go through")
        #expect(!StrictGuard.vetoesQuit(liveStrict: true, systemIsEnding: false, updatePermitted: true), "an update goes through")
    }

    @Test func anUpdatePermitCountsOnlyWhileFresh() {
        #expect(StrictGuard.permitIsFresh(writtenAt: now.addingTimeInterval(-10), now: now))
        #expect(!StrictGuard.permitIsFresh(writtenAt: now.addingTimeInterval(-StrictGuard.updatePermitLifetime - 1), now: now))
        #expect(!StrictGuard.permitIsFresh(writtenAt: nil, now: now))
        #expect(!StrictGuard.permitIsFresh(writtenAt: now.addingTimeInterval(3600), now: now), "a permit from the future is not one")
    }

    @Test func thePermitFileIsReadFromItsDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-permit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!UpdatePermit.isFresh(in: dir))
        FileManager.default.createFile(atPath: UpdatePermit.url(in: dir).path, contents: Data())
        #expect(UpdatePermit.isFresh(in: dir))
        UpdatePermit.clear(in: dir)
        #expect(!UpdatePermit.isFresh(in: dir))
    }

    @Test func relaunchesBackOff() {
        #expect(StrictGuard.relaunchDelay(recent: 0) == 1)
        #expect(StrictGuard.relaunchDelay(recent: 3) == 8)
        #expect(StrictGuard.relaunchDelay(recent: 50) == 60)
    }

    @Test func theLaunchAgentPlistMatchesTheCode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/\(StrictGuard.agentPlistName)")
        let plist = try #require(NSDictionary(contentsOf: url))
        #expect(plist["Label"] as? String == StrictGuard.agentLabel)
        #expect((plist["ProgramArguments"] as? [String])?.contains(StrictGuard.watcherFlag) == true)
        let keepAlive = plist["KeepAlive"] as? [String: Any]
        #expect((keepAlive?["PathState"] as? [String: Bool])?[StrictGuard.markerPath] == true,
                "kept up only while the strict-session marker exists")
        #expect(plist["RunAtLoad"] == nil, "not started at login for nothing")
    }
}

private extension SessionRecord {
    var encodedForTest: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
