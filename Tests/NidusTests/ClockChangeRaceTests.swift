//
//  ClockChangeRaceTests.swift
//  NidusTests
//
//  The notice that the date was set arrives on the main queue, after
//  whatever was already queued there. Something done in between (a pause, a
//  wake-up of the recorder) reads the new clock before Nidus knows it moved.
//  Neither may be shifted twice or closed on the wrong clock.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
private final class QuietHost: ActivityRecorderHost {
    var front: ActivityFrontApp? = ActivityFrontApp(id: "com.microsoft.Word", name: "Word", pid: 11)
    func frontApp() -> ActivityFrontApp? { front }
    func secondsSinceInput() -> TimeInterval { 0 }
    func probe(_ app: ActivityFrontApp, titles: Bool, completion: @escaping @MainActor (ActivityDetail?) -> Void) {
        completion(nil)
    }
    func arm(after seconds: TimeInterval?, fire: @escaping @MainActor () -> Void) {}
}

@MainActor
struct ClockChangeRaceTests {
    private let minute: TimeInterval = 60

    // MARK: The pause reminder

    private func engine(_ clocks: TwoClocks) -> (SessionEngine, EventLog) {
        let engine = SessionEngine(store: MemoryStore(), now: { clocks.wall }, monotonic: { clocks.mono })
        let events = EventLog()
        engine.onEvent = { events.all.append($0) }
        return (engine, events)
    }

    private func lingering(_ events: EventLog) -> Int { events.all.filter { $0 == .pauseLingering }.count }

    private let plan = SessionPlan(goal: "Write", duration: 60 * 60, mode: .block, apps: [], websites: [])

    @Test func aPauseBetweenABackwardChangeAndItsNoticeIsNotRemindedAtOnce() {
        let clocks = TwoClocks()
        let (engine, events) = engine(clocks)
        engine.start(plan)
        clocks.advance(5 * minute)
        clocks.setClock(by: -3600)
        engine.pause()
        engine.systemClockDidChange()
        clocks.advance(minute)
        engine.tick()
        #expect(lingering(events) == 0, "one minute into the pause")
        clocks.advance(9 * minute)
        engine.tick()
        #expect(lingering(events) == 1, "ten minutes into it")
    }

    @Test func aPauseBetweenAForwardChangeAndItsNoticeIsRemindedOnTime() {
        let clocks = TwoClocks()
        let (engine, events) = engine(clocks)
        engine.start(plan)
        clocks.advance(5 * minute)
        clocks.setClock(by: 3600)
        engine.pause()
        engine.systemClockDidChange()
        clocks.advance(10 * minute)
        engine.tick()
        #expect(lingering(events) == 1)
    }

    @Test func aPauseBeforeTheChangeStillCountsItsRealLength() {
        let clocks = TwoClocks()
        let (engine, events) = engine(clocks)
        engine.start(plan)
        engine.pause()
        clocks.advance(4 * minute)
        clocks.setClock(by: -3600)
        engine.systemClockDidChange()
        clocks.advance(5 * minute)
        engine.tick()
        #expect(lingering(events) == 0)
        clocks.advance(minute)
        engine.tick()
        #expect(lingering(events) == 1)
    }

    // MARK: The recorder

    @MainActor
    private struct Rig {
        let clocks = TwoClocks()
        let host = QuietHost()
        let recorder: ActivityRecorder

        init() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            clocks.wall = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!
            let clocks = clocks
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-clock-race-\(UUID().uuidString)")
            recorder = ActivityRecorder(store: ActivityDayStore(directory: directory), host: host,
                                        now: { clocks.wall }, calendar: calendar, uptime: { clocks.mono })
            recorder.apply(ActivityRecorderSettings(enabled: true))
        }
    }

    @Test func aWakeUpAfterABackwardChangeKeepsTheStretch() {
        let rig = Rig()
        rig.recorder.start()
        rig.clocks.advance(600)
        rig.recorder.frontAppDidChange()
        rig.clocks.setClock(by: -3600)
        // A wake-up runs before the notice.
        rig.recorder.frontAppDidChange()
        rig.recorder.clockDidChange()
        rig.clocks.advance(60)
        #expect(rig.recorder.today().stretches.allSatisfy { $0.end > $0.start })
        #expect(rig.recorder.today().seconds == 660, "ten minutes before the change, one after")
    }

    @Test func aWakeUpAfterAForwardChangeCountsNoPhantomHour() {
        let rig = Rig()
        rig.recorder.start()
        rig.clocks.advance(600)
        rig.recorder.frontAppDidChange()
        rig.clocks.setClock(by: 3600)
        rig.recorder.frontAppDidChange()
        rig.recorder.clockDidChange()
        rig.clocks.advance(60)
        #expect(rig.recorder.today().seconds == 660)
    }

    @Test func theNoticeAloneStillSettlesTheChange() {
        let rig = Rig()
        rig.recorder.start()
        rig.clocks.advance(600)
        rig.recorder.frontAppDidChange()
        rig.clocks.setClock(by: -3600)
        rig.recorder.clockDidChange()
        rig.clocks.advance(60)
        #expect(rig.recorder.today().seconds == 660)
    }

    @Test func sleepIsNotMistakenForAChange() {
        let rig = Rig()
        rig.recorder.start()
        rig.clocks.advance(600)
        rig.recorder.frontAppDidChange()
        rig.recorder.systemWillSleep()
        // Asleep: the wall clock moves, uptime doesn't.
        rig.clocks.setClock(by: 3600)
        rig.recorder.systemDidWake()
        rig.clocks.advance(60)
        rig.recorder.frontAppDidChange()
        #expect(rig.recorder.today().seconds == 660)
    }
}
