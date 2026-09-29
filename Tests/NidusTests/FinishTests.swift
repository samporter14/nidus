//
//  FinishTests.swift
//  NidusTests
//
//  1.4: "did you finish?" on the wrap-up card, kept with the session and
//  counted in the stats.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct FinishTests {
    @Test func historyFromBeforeTheQuestionLoadsUnanswered() throws {
        let json = #"{"version":1,"sessions":[{"id":"6A1C2A8E-2A41-4B6B-9C3D-3F4A1E5B6C7D","start":800000000,"end":800001500,"focused":1500,"planned":1500,"outcome":"completed","goal":"x","blocks":{},"quits":{},"foreground":{},"names":{}}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("finish-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let history = FocusHistory(url: url)
        #expect(history.sessions.count == 1)
        #expect(history.sessions[0].finished == nil)
    }

    @Test func anAnswerIsKeptWithTheSession() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("finish-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = FocusHistory(url: url)
        let entry = StatsTests.entry(0, minutes: 25)
        history.append(entry)
        #expect(history.setFinished(entry.id, true))
        #expect(!history.setFinished(UUID(), true), "an unknown session changes nothing")
        #expect(FocusHistory(url: url).sessions.first?.finished == true, "saved to the file")
    }

    @Test func statsCountOnlyAnsweredGoals() {
        var a = StatsTests.entry(-2, minutes: 25); a.finished = true
        var b = StatsTests.entry(-1, minutes: 25); b.finished = false
        var c = StatsTests.entry(0, minutes: 25); c.finished = true
        let d = StatsTests.entry(0, minutes: 30)
        let s = FocusStats(sessions: [a, b, c, d], now: StatsTests.now, calendar: StatsTests.calendar)
        #expect(s.goalsAnswered == 3)
        #expect(s.goalsFinished == 2)
    }
}

struct AppleFocusTests {
    @Test func theShortcutsCarryTheAppsName() {
        #expect(FocusShortcuts.doNotDisturbOn == "Nidus · Do Not Disturb on")
        #expect(FocusShortcuts.doNotDisturbOff == "Nidus · Do Not Disturb off")
        #expect(FocusShortcuts.appleFocuses.allSatisfy { $0.onShortcut.hasPrefix("Nidus · ") && $0.offShortcut.hasPrefix("Nidus · ") })
        #expect(FocusShortcuts.doNotDisturb.id == "com.apple.donotdisturb.mode.default")
    }

    @Test func everyModeIsDistinct() {
        let modes = FocusShortcuts.appleFocuses
        #expect(Set(modes.map(\.id)).count == modes.count)
        #expect(Set(modes.map(\.onShortcut)).count == modes.count)
    }

    @Test(arguments: FocusShortcuts.appleFocuses)
    func aShortcutSetsItsOwnMode(_ focus: FocusShortcuts.AppleFocus) throws {
        for on in [true, false] {
            let flow = FocusShortcuts.workflow(for: focus, enabling: on)
            let action = try #require((flow["WFWorkflowActions"] as? [[String: Any]])?.first)
            #expect(action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.dnd.set")
            let parameters = try #require(action["WFWorkflowActionParameters"] as? [String: Any])
            let mode = try #require(parameters["FocusModes"] as? [String: String])
            #expect(mode["Identifier"] == focus.id && mode["DisplayString"] == focus.name)
            #expect(parameters["Enabled"] as? Int == (on ? 1 : 0))
            #expect((try? PropertyListSerialization.data(fromPropertyList: flow, format: .binary, options: 0)) != nil)
        }
    }
}

/// 1.3.3: a locked Mac is not focusing.
@MainActor
struct AwayTests {
    @Test func lockingPausesAndUnlockingResumes() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-away-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.start()
        // Block mode with nothing listed: acts on no app and asks no browser.
        controller.start(SessionPlan(goal: "", duration: 25 * 60, mode: .block, apps: [], websites: []))

        controller.screenDidLock()
        #expect(controller.engine.isPaused, "a locked Mac is not focusing")
        controller.screenDidUnlock()
        #expect(controller.engine.isRunning)

        // Asleep while locked: the wake lands on the lock screen, still away.
        controller.screenDidLock()
        controller.systemWillSleep()
        controller.systemDidWake()
        #expect(controller.engine.isPaused, "waking to the lock screen is still away")
        controller.screenDidUnlock()
        #expect(controller.engine.isRunning)

        // A pause the user chose survives a lock and an unlock.
        controller.pause()
        controller.screenDidLock()
        controller.screenDidUnlock()
        #expect(controller.engine.isPaused)

        controller.end()
        controller.stop()
    }
}

@MainActor
struct AwayKeepsBlockingTests {
    @Test func sleepFreezesTheCountdownButKeepsBlocking() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.systemWillSleep()
        #expect(h.engine.isPaused)
        #expect(h.engine.enforcement?.websites == ["youtube.com"], "nothing is undone behind a locked or sleeping screen")
        h.engine.systemDidWake()
        #expect(h.engine.enforcement?.websites == ["youtube.com"])
    }

    @Test func aPauseTheUserChoseStillLiftsTheBlock() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.pause()
        #expect(h.engine.enforcement == nil)
    }

    @Test func lockingKeepsTheSessionBlocking() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.start()
        // An app ID no app has: nothing real is ever blocked by this test.
        controller.start(SessionPlan(goal: "", duration: 25 * 60, mode: .block, apps: ["invalid.nidus.test"], websites: []))
        controller.screenDidLock()
        #expect(controller.engine.isPaused)
        #expect(controller.engine.enforcement?.apps == ["invalid.nidus.test"])
        controller.screenDidUnlock()
        #expect(controller.engine.isRunning && controller.engine.enforcement != nil)
        controller.end()
        controller.stop()
    }
}
