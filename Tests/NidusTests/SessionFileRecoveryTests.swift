//
//  SessionFileRecoveryTests.swift
//  NidusTests
//
//  A session file that will not read is set aside, not written over; the
//  backup of the write before it is tried; and one wrongly written field loses
//  only itself.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct SessionFileRecoveryTests {
    let dir: URL
    var url: URL { dir.appendingPathComponent("session.json") }
    var backup: URL { dir.appendingPathComponent("session.json.bak") }
    let clock = TestClock()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func engine() -> SessionEngine {
        let clock = clock
        return SessionEngine(store: FileSessionStore(url: url, now: { clock.now }), now: { clock.now })
    }

    private func asides() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session.unreadable-") }
    }

    /// Whether the problem names `aside` (temp paths may differ by a symlink).
    private func sameFile(_ problem: SessionLoadProblem?, _ aside: URL) -> Bool {
        switch problem {
        case .recoveredFromBackup(let url?), .unreadable(let url?):
            return url.resolvingSymlinksInPath().path == aside.resolvingSymlinksInPath().path
        default: return false
        }
    }

    /// A session written by a real engine, to be damaged by hand.
    private func goodFile() throws -> Data {
        let writer = engine()
        writer.start(plan(25))
        return try Data(contentsOf: url)
    }

    @Test func aMissingFileIsNoProblem() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engine()
        engine.restore()
        #expect(engine.session == nil)
        #expect(engine.loadProblem == nil)
        #expect(asides().isEmpty)
    }

    @Test func aSavedFileIsNoProblem() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = engine()
        writer.start(plan(25))
        let reader = engine()
        reader.restore()
        #expect(reader.session != nil)
        #expect(reader.loadProblem == nil)
    }

    @Test func garbageIsSetAsideAndReported() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: url)
        let engine = engine()
        engine.restore()
        #expect(engine.session == nil)
        let aside = try #require(asides().first)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: aside) == Data("{ not json".utf8))
        #expect(sameFile(engine.loadProblem, aside))
        if case .unreadable? = engine.loadProblem {} else { Issue.record("expected .unreadable") }
    }

    @Test func garbageWithAGoodBackupRestoresFromTheBackup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try goodFile()
        try good.write(to: backup)
        try Data("garbage".utf8).write(to: url)
        let engine = engine()
        engine.restore()
        let aside = try #require(asides().first)
        #expect(engine.session?.plan.goal == "Write the report")
        #expect(sameFile(engine.loadProblem, aside))
        if case .recoveredFromBackup? = engine.loadProblem {} else { Issue.record("expected .recoveredFromBackup") }
        // The good copy is the file again.
        #expect(try Data(contentsOf: url) == good)
    }

    @Test func garbageWithAGarbageBackupIsLost() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("garbage".utf8).write(to: backup)
        try Data("garbage".utf8).write(to: url)
        let engine = engine()
        engine.restore()
        #expect(engine.session == nil)
        if case .unreadable? = engine.loadProblem {} else { Issue.record("expected .unreadable") }
    }

    @Test func aSessionThatCannotDecodeIsNotSilentlyDropped() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // A session with no plan: the record would read as "no session".
        try Data(#"{"session":{"startedAt":1,"budget":5}}"#.utf8).write(to: url)
        let engine = engine()
        engine.restore()
        #expect(engine.session == nil)
        #expect(!asides().isEmpty)
        if case .unreadable? = engine.loadProblem {} else { Issue.record("expected .unreadable") }
    }

    @Test func aSaveWritesTheBackup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engine()
        engine.start(plan(25))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let first = try Data(contentsOf: url)
        engine.extend(by: 5 * minute)
        // The backup is the file as it was before this save.
        #expect(try Data(contentsOf: backup) == first)
        #expect(try Data(contentsOf: url) != first)
    }

    @Test func aBadModeAndStrictStillRestoreTheSession() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var json = try #require(JSONSerialization.jsonObject(with: goodFile()) as? [String: Any])
        var session = try #require(json["session"] as? [String: Any])
        var plan = try #require(session["plan"] as? [String: Any])
        plan["mode"] = "nonsense"
        plan["strict"] = "yes"
        session["plan"] = plan
        json["session"] = session
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let engine = engine()
        engine.restore()
        #expect(engine.session?.plan.mode == .block)
        #expect(engine.session?.plan.strict == false)
        #expect(engine.loadProblem == nil)
    }

    @Test func aBadBookkeepingFieldLosesOnlyItself() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var json = try #require(JSONSerialization.jsonObject(with: goodFile()) as? [String: Any])
        var session = try #require(json["session"] as? [String: Any])
        for key in ["snoozes", "quitApps", "blocks", "quitCounts", "foreground", "names", "seenElapsed", "endedAt", "focusedTime"] {
            session[key] = "wrong"
        }
        json["session"] = session
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let engine = engine()
        engine.restore()
        #expect(engine.session != nil)
        #expect(engine.session?.snoozes.isEmpty == true)
        #expect(engine.session?.seenElapsed == 0)
        #expect(engine.loadProblem == nil)
    }
}
