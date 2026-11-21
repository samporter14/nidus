//
//  ActivityDaySaveTests.swift
//  NidusTests
//
//  A day file that can't be decoded is kept, not written over; one that
//  can't be opened is left alone until it can; and a write that fails keeps
//  today unsaved, so the next save writes the latest state.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
private final class StillHost: ActivityRecorderHost {
    var front: ActivityFrontApp? = ActivityFrontApp(id: "com.microsoft.Word", name: "Word", pid: 11)
    private var fire: (@MainActor () -> Void)?
    func frontApp() -> ActivityFrontApp? { front }
    func secondsSinceInput() -> TimeInterval { 0 }
    func probe(_ app: ActivityFrontApp, titles: Bool, completion: @escaping @MainActor (ActivityDetail?) -> Void) {
        completion(nil)
    }
    func arm(after seconds: TimeInterval?, fire: @escaping @MainActor () -> Void) {
        self.fire = seconds == nil ? nil : fire
    }
    func wake() { fire?() }
}

@MainActor
struct ActivityDaySaveTests {
    private let day = "2026-11-04"

    @MainActor
    private struct Rig {
        let clock = TestClock()
        let host = StillHost()
        let directory: URL
        let store: ActivityDayStore
        let recorder: ActivityRecorder

        init(directory: URL, at start: String = "2026-11-04T09:00:00Z") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            clock.now = ISO8601DateFormatter().date(from: start)!
            self.directory = directory
            store = ActivityDayStore(directory: directory)
            let clock = clock
            recorder = ActivityRecorder(store: store, host: host, now: { clock.now }, calendar: calendar)
            recorder.apply(ActivityRecorderSettings(enabled: true))
        }

        func work(_ seconds: TimeInterval) { clock.advance(seconds); host.wake() }

        /// Lets the store finish and its outcome reach the recorder.
        func settle() async {
            store.flush()
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-day-save-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func setAsideFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".corrupt-") }
    }

    @Test func aMissingFileReadsAsAbsentAndAMalformedOneAsCorrupt() throws {
        let dir = folder()
        let store = ActivityDayStore(directory: dir)
        #expect(store.loadFile(day: day) == .absent)
        try Data("{not json".utf8).write(to: store.url(for: day))
        #expect(store.loadFile(day: day) == .corrupt)
    }

    @Test func anUnreadableFileIsNotTheSameAsAMissingOne() throws {
        let dir = folder()
        let store = ActivityDayStore(directory: dir)
        let file = store.url(for: day)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(store.loadFile(day: day) == .inaccessible)
        #expect(store.load(day: day) == nil)
    }

    @Test func aMalformedDayIsKeptBesideTheNewOne() async throws {
        let dir = folder()
        let original = Data("{\"day\":\"2026-11-04\",\"stretches\":[{broken".utf8)
        try original.write(to: dir.appendingPathComponent("\(day).json"))
        let rig = Rig(directory: dir)
        rig.recorder.start()
        rig.work(60)
        rig.recorder.stop()
        await rig.settle()

        let aside = setAsideFiles(in: dir)
        #expect(aside.count == 1)
        if let name = aside.first {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == original, "the bytes are kept as they were")
        }
        #expect(rig.store.load(day: day)?.seconds == 60, "the new day is written")
        #expect(!rig.recorder.savesFailing)
    }

    @Test func anUnreadableDayIsNotWrittenOverAndIsJoinedOnceReadable() async throws {
        let dir = folder()
        // Earlier today, from another run.
        let earlier = Rig(directory: dir)
        earlier.recorder.start()
        earlier.work(30)
        earlier.recorder.stop()
        await earlier.settle()
        let file = dir.appendingPathComponent("\(day).json")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let rig = Rig(directory: dir)
        rig.clock.now = earlier.clock.now.addingTimeInterval(60)
        rig.recorder.start()
        #expect(rig.recorder.savesFailing)
        rig.work(150)
        await rig.settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before, "never written over while it couldn't be read")
        #expect(rig.recorder.savesFailing)

        // Readable again: the next save keeps both runs.
        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 330)
        #expect(!rig.recorder.savesFailing)
    }

    @Test func aFailedWriteIsTriedAgainWithTheLatestState() async throws {
        let dir = folder()
        let rig = Rig(directory: dir)
        rig.recorder.start()
        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 150)

        // The folder stops taking writes.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        rig.work(150)
        await rig.settle()
        #expect(rig.recorder.savesFailing)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(rig.store.load(day: day)?.seconds == 150)

        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 450, "the retry writes everything, not only the last part")
        #expect(!rig.recorder.savesFailing)
    }

    @Test func aFailureBeforeAClearDoesNotBringTheDayBack() async throws {
        let dir = folder()
        let rig = Rig(directory: dir)
        rig.recorder.start()
        rig.work(150)
        await rig.settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        rig.work(150)
        await rig.settle()
        #expect(rig.recorder.savesFailing)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        rig.host.front = nil
        rig.recorder.clear()
        rig.work(150)
        rig.recorder.stop()
        await rig.settle()
        #expect(rig.store.load(day: day) == nil, "nothing from before the clear is written again")
        #expect(!rig.recorder.savesFailing)
    }

    // MARK: Past days

    private let nextDay = "2026-11-05"

    private func lock(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    }

    private func unlock(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @Test func aFailedWriteOfTheDayJustEndedIsTriedAgain() async throws {
        let dir = folder()
        let rig = Rig(directory: dir, at: "2026-11-04T23:57:00Z")
        rig.recorder.start()
        rig.work(60)
        await rig.settle()
        // The folder stops taking writes as the day turns.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        rig.work(300)
        await rig.settle()
        #expect(rig.recorder.retainedPastDays == [day], "yesterday's record is held, not dropped")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        rig.work(150)
        await rig.settle()
        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 180, "the whole of the old day, once")
        #expect(rig.store.load(day: nextDay)?.seconds ?? 0 > 300)
        #expect(rig.recorder.retainedPastDays.isEmpty)
    }

    @Test func aStretchAcrossMidnightKeepsTheEarlierDayUntilItCanBeRead() async throws {
        let dir = folder()
        // Yesterday already has a file, from before.
        let earlier = Rig(directory: dir, at: "2026-11-04T10:00:00Z")
        earlier.recorder.start()
        earlier.work(100)
        earlier.recorder.stop()
        await earlier.settle()
        let file = dir.appendingPathComponent("\(day).json")
        let before = try Data(contentsOf: file)

        // It can't be read from the moment this run starts, through midnight.
        try lock(file)
        defer { unlock(file) }
        let rig = Rig(directory: dir, at: "2026-11-04T23:59:00Z")
        rig.recorder.start()
        rig.work(30)
        rig.clock.advance(60)
        rig.host.wake()
        await rig.settle()
        #expect(rig.recorder.retainedPastDays == [day])
        unlock(file)
        #expect(try Data(contentsOf: file) == before, "never written over while it couldn't be read")

        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 160, "the earlier time and the stretch up to midnight, once each")
        #expect(rig.recorder.retainedPastDays.isEmpty)
        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 160)
    }

    @Test func midnightWithTheOldDaysFileUnreadableHoldsItsTimeAndJoinsItLater() async throws {
        let dir = folder()
        let earlier = Rig(directory: dir, at: "2026-11-04T10:00:00Z")
        earlier.recorder.start()
        earlier.work(100)
        earlier.recorder.stop()
        await earlier.settle()
        let file = dir.appendingPathComponent("\(day).json")
        let before = try Data(contentsOf: file)

        let rig = Rig(directory: dir, at: "2026-11-04T23:59:00Z")
        rig.recorder.start()
        rig.work(30)
        rig.recorder.systemWillSleep()
        try lock(file)
        defer { unlock(file) }
        rig.clock.advance(90)
        rig.recorder.systemDidWake()
        rig.work(30)
        await rig.settle()
        unlock(file)
        #expect(try Data(contentsOf: file) == before, "never written over while it couldn't be read")
        unlock(file)

        // Readable again: the retry joins the file, keeping what was there.
        rig.work(150)
        await rig.settle()
        let joined = rig.store.load(day: day)
        #expect(joined?.seconds == 130)
        #expect(rig.recorder.retainedPastDays.isEmpty)
        // And not a second time.
        rig.work(150)
        await rig.settle()
        #expect(rig.store.load(day: day)?.seconds == 130)
    }

    @Test func aCorruptPastDayIsSetAsideNotWrittenOver() async throws {
        let dir = folder()
        let original = Data("{\"day\":\"2026-11-04\",\"stretches\":[{broken".utf8)
        try original.write(to: dir.appendingPathComponent("\(day).json"))
        let rig = Rig(directory: dir, at: "2026-11-04T23:59:30Z")
        rig.recorder.start()
        rig.work(120)
        await rig.settle()
        let aside = setAsideFiles(in: dir)
        #expect(aside.count == 1)
        if let name = aside.first {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == original)
        }
        #expect(rig.store.load(day: day)?.seconds == 30)
        #expect(rig.recorder.retainedPastDays.isEmpty)
    }

    @Test func theHeldPastDaysAreBounded() async throws {
        let dir = folder()
        let rig = Rig(directory: dir, at: "2026-11-04T23:59:00Z")
        rig.recorder.start()
        // Every old day's file is unreadable, and days keep going by.
        for offset in 0..<(ActivityRecorder.maxRetainedPastDays + 4) {
            let key = String(format: "2026-11-%02d", 4 + offset)
            let file = dir.appendingPathComponent("\(key).json")
            try Data("{}".utf8).write(to: file)
            try lock(file)
        }
        defer {
            for offset in 0..<(ActivityRecorder.maxRetainedPastDays + 4) {
                unlock(dir.appendingPathComponent(String(format: "2026-11-%02d.json", 4 + offset)))
            }
        }
        for _ in 0..<(ActivityRecorder.maxRetainedPastDays + 4) {
            rig.work(120)
            rig.clock.advance(86_400 - 120)
            rig.host.wake()
        }
        await rig.settle()
        #expect(rig.recorder.retainedPastDays.count <= ActivityRecorder.maxRetainedPastDays)
        #expect(!rig.recorder.retainedPastDays.isEmpty)
    }
}
