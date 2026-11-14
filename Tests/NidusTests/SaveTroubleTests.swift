//
//  SaveTroubleTests.swift
//  NidusTests
//
//  A save that fails is noticed, not dropped: the session file and the
//  history file say so, and the next save writes the latest state. A quit
//  and the block that follows it are written once, not twice.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct SaveTroubleTests {
    private final class CountingStore: SessionStore {
        var saves = 0
        func load() -> SessionRecord? { nil }
        func save(_ record: SessionRecord) { saves += 1 }
    }

    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-save-trouble-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let plan = SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: ["com.example.game"], websites: [])

    @Test func aSessionSaveThatFailsIsReportedAndCaughtUpByTheNext() throws {
        let dir = folder()
        let store = FileSessionStore(url: dir.appendingPathComponent("session.json"))
        let engine = SessionEngine(store: store, now: Date.init)
        engine.start(plan)
        #expect(!engine.saveFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        engine.recordBlock("com.example.game", name: "Game")
        #expect(engine.saveFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        engine.persist()
        #expect(!engine.saveFailed)
        let saved = FileSessionStore(url: dir.appendingPathComponent("session.json")).load()
        #expect(saved?.session?.blocks["com.example.game"] == 1, "the retry writes the latest state")
    }

    @Test func aHistoryWriteThatFailsIsReportedAndRetried() throws {
        let dir = folder()
        let url = dir.appendingPathComponent("history.json")
        let history = FocusHistory(url: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        history.clear()
        history.retrySave()
        history.flush()
        // Removing a file that isn't there is not a failure.
        #expect(!history.saveFailed)

        let writer = HistoryFileWriter(url: url)
        writer.enqueue(.write([]))
        writer.flush()
        #expect(writer.lastWriteFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        writer.enqueue(.write([]))
        writer.flush()
        #expect(!writer.lastWriteFailed)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aQuitCanWaitForTheBlockToSaveIt() {
        let store = CountingStore()
        let engine = SessionEngine(store: store, now: Date.init)
        engine.start(plan)
        let before = store.saves
        engine.recordQuit("com.example.game", name: "Game", save: false)
        engine.recordBlock("com.example.game", name: "Game")
        #expect(store.saves == before + 1)
        #expect(engine.session?.quitApps == ["com.example.game"])
        #expect(engine.session?.blocks["com.example.game"] == 1)
    }

    @Test func aMemoryStoreNeverFails() {
        let engine = SessionEngine(store: CountingStore(), now: Date.init)
        engine.start(plan)
        #expect(!engine.saveFailed)
    }
}
