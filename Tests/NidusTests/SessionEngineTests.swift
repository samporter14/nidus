//
//  SessionEngineTests.swift
//  NidusTests
//

import Foundation
import Testing
@testable import Nidus

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor
final class MemoryStore: SessionStore {
    var record: SessionRecord?
    func load() -> SessionRecord? { record }
    func save(_ record: SessionRecord) { self.record = record }
}

@MainActor
struct Harness {
    let clock = TestClock()
    let store = MemoryStore()
    let engine: SessionEngine
    let events: EventLog

    init() {
        let clock = clock
        engine = SessionEngine(store: store, now: { clock.now })
        let events = EventLog()
        engine.onEvent = { events.all.append($0) }
        self.events = events
    }

    /// A second engine on the same store: Droppy relaunching.
    func relaunch() -> (SessionEngine, EventLog) {
        let clock = clock
        let engine = SessionEngine(store: store, now: { clock.now })
        let events = EventLog()
        engine.onEvent = { events.all.append($0) }
        engine.restore()
        return (engine, events)
    }
}

@MainActor
final class EventLog {
    var all: [SessionEvent] = []
    var last: SessionEvent? { all.last }
}

let minute: TimeInterval = 60

func plan(_ minutes: Double? = 25, mode: SessionPlan.Mode = .block,
          apps: [String] = ["com.tinyspeck.slackmacgap"], websites: [String] = ["youtube.com"]) -> SessionPlan {
    SessionPlan(goal: "Write the report", duration: minutes.map { $0 * minute }, mode: mode, apps: apps, websites: websites)
}

@MainActor
struct CountdownTests {
    @Test func startRunsForTheFullDuration() {
        let h = Harness()
        h.engine.start(plan(25))
        #expect(h.engine.isRunning)
        #expect(h.engine.remaining == 25 * minute)
        #expect(h.engine.elapsed == 0)
        #expect(h.events.all == [.started])
        #expect(h.engine.lastPlan == plan(25))
    }

    @Test func endsAtTheDeadlineAndNotBefore() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute - 1)
        h.engine.tick()
        #expect(h.engine.isRunning)
        #expect(h.engine.remaining == 1)

        h.clock.advance(1)
        h.engine.tick()
        #expect(h.engine.session == nil)
        guard case .ended(.completed, let final)? = h.events.last else {
            Issue.record("expected a completed end, got \(String(describing: h.events.last))"); return
        }
        #expect(final.plan == plan(25))
        #expect(h.engine.lastPlan == plan(25), "the shortcut restarts the last plan")
    }

    @Test func aLateTickDoesNotDriftTheDeadline() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(10 * minute)   // no ticks for ten minutes
        #expect(h.engine.remaining == 15 * minute)
    }

    @Test func openEndedCountsUpAndStopsAtTheCap() {
        let h = Harness()
        h.engine.start(plan(nil))
        h.clock.advance(90 * minute)
        #expect(h.engine.elapsed == 90 * minute)
        h.clock.advance(SessionPlan.maximumDuration)
        h.engine.tick()
        #expect(h.engine.session == nil)
    }

    @Test func durationsAboveTheCapAreCapped() {
        let h = Harness()
        h.engine.start(plan(48 * 60))
        #expect(h.engine.remaining == SessionPlan.maximumDuration)
    }

    @Test func endEarlyReportsTheReasonAndClearsEnforcement() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.end()
        #expect(h.engine.session == nil)
        #expect(h.engine.enforcement == nil)
        guard case .ended(.endedEarly, _)? = h.events.last else { Issue.record("no early end"); return }
    }

    @Test func startingOverARunningSessionEndsItFirst() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.start(plan(50))
        guard h.events.all.count == 3, case .ended(.endedEarly, _) = h.events.all[1] else {
            Issue.record("expected started, ended, started: \(h.events.all)"); return
        }
        #expect(h.engine.remaining == 50 * minute)
    }
}

@MainActor
struct PauseAndSleepTests {
    @Test func pauseFreezesTheCountdownAndLiftsTheBlock() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(5 * minute)
        h.engine.pause()
        #expect(h.engine.enforcement == nil)

        h.clock.advance(60 * minute)
        h.engine.tick()
        #expect(h.engine.remaining == 20 * minute, "a paused session never ends on its own")

        h.engine.resume()
        #expect(h.engine.remaining == 20 * minute)
        #expect(h.engine.enforcement != nil)
        #expect(h.engine.elapsed == 5 * minute)
    }

    @Test func sleepPausesAndWakeResumes() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(5 * minute)
        h.engine.systemWillSleep()
        h.clock.advance(8 * 60 * minute)
        h.engine.systemDidWake()
        #expect(h.engine.isRunning)
        #expect(h.engine.remaining == 20 * minute)
    }

    @Test func wakeDoesNotResumeAPauseTheUserChose() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.pause()
        h.engine.systemWillSleep()
        h.engine.systemDidWake()
        #expect(h.engine.isPaused)
    }
}

@MainActor
struct ExtendTests {
    @Test func extendAddsTimeAndDoesNotCountAsElapsed() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(20 * minute)
        h.engine.extend(by: 10 * minute)
        #expect(h.engine.remaining == 15 * minute)
        #expect(h.engine.elapsed == 20 * minute)
        #expect(h.events.last == .extended)
    }

    @Test func extendWorksWhilePaused() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.pause()
        h.engine.extend(by: 5 * minute)
        #expect(h.engine.remaining == 30 * minute)
    }

    @Test func extendNeverLeavesMoreThanTheCap() {
        let h = Harness()
        h.engine.start(plan(23 * 60))
        h.engine.extend(by: 5 * 60 * minute)
        #expect(h.engine.remaining == SessionPlan.maximumDuration)
        h.engine.extend(by: minute)
        #expect(h.events.last == .extended && h.events.all.filter { $0 == .extended }.count == 1,
                "an extension that adds nothing is not reported")
    }
}

@MainActor
struct SnoozeTests {
    @Test func snoozeLetsOneItemThroughForThreeMinutes() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.snooze("youtube.com")
        #expect(h.engine.enforcement?.websites == [])
        #expect(h.engine.enforcement?.apps == ["com.tinyspeck.slackmacgap"], "other items stay blocked")

        h.clock.advance(3 * minute - 1)
        h.engine.tick()
        #expect(h.engine.enforcement?.websites == [])

        h.clock.advance(1)
        h.engine.tick()
        #expect(h.engine.enforcement?.websites == ["youtube.com"])
        #expect(h.events.last == .snoozeEnded("youtube.com"))
    }

    @Test func inAllowModeASnoozeAllowsTheItem() {
        let h = Harness()
        h.engine.start(plan(25, mode: .allow, apps: ["com.apple.dt.Xcode"], websites: ["developer.apple.com"]))
        h.engine.snooze("com.apple.MobileSMS")
        #expect(h.engine.enforcement?.apps == ["com.apple.dt.Xcode", "com.apple.MobileSMS"])
    }

    @Test func snoozeIsIgnoredUnlessRunning() {
        let h = Harness()
        h.engine.snooze("youtube.com")
        h.engine.start(plan(25))
        h.engine.pause()
        h.engine.snooze("youtube.com")
        #expect(h.engine.session?.snoozes.isEmpty == true)
    }
}

@MainActor
struct PersistenceTests {
    @Test func aRelaunchResumesTheSession() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.snooze("youtube.com")
        h.engine.recordQuit("com.tinyspeck.slackmacgap")
        h.clock.advance(10 * minute)

        let (engine, events) = h.relaunch()
        #expect(engine.isRunning)
        #expect(engine.remaining == 15 * minute)
        #expect(engine.session?.snoozes.keys.contains("youtube.com") == true)
        #expect(engine.session?.quitApps == ["com.tinyspeck.slackmacgap"])
        #expect(events.all.isEmpty, "resuming is not an event")
    }

    @Test func aDeadlinePassedWhileAwayEndsOnRelaunch() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(3 * 60 * minute)

        let (engine, events) = h.relaunch()
        #expect(engine.session == nil)
        guard case .ended(.expiredWhileAway, _)? = events.last else {
            Issue.record("expected expiredWhileAway, got \(events.all)"); return
        }
        #expect(engine.lastPlan == plan(25))
    }

    @Test func aSleepPauseMissedByARelaunchResumes() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.systemWillSleep()
        h.clock.advance(60 * minute)
        let (engine, _) = h.relaunch()
        #expect(engine.isRunning)
        #expect(engine.remaining == 25 * minute)
    }

    @Test func aUserPauseSurvivesARelaunch() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.pause()
        let (engine, _) = h.relaunch()
        #expect(engine.isPaused)
    }

    @Test func extensionsSurviveARelaunch() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(20 * minute)
        h.engine.extend(by: 10 * minute)
        let (engine, _) = h.relaunch()
        #expect(engine.elapsed == 20 * minute)
    }

    @Test func theFileStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-tests-\(UUID().uuidString)/session.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileSessionStore(url: url)
        #expect(store.load() == nil)

        let clock = TestClock()
        let engine = SessionEngine(store: store, now: { clock.now })
        engine.start(plan(25))
        engine.pause()

        let reloaded = SessionEngine(store: FileSessionStore(url: url), now: { clock.now })
        reloaded.restore()
        #expect(reloaded.session == engine.session)
        #expect(reloaded.lastPlan == plan(25))
    }
}
