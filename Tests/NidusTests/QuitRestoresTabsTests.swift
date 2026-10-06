//
//  QuitRestoresTabsTests.swift
//  NidusTests
//
//  Quitting mid-session puts blocked tabs back, and the session that resumes
//  blocks them again without counting it. The browsers themselves can't be
//  driven here (no Apple Events in tests); this holds the bookkeeping: the
//  marker quitting leaves, and what the next start makes of it.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct QuitRestoresTabsTests {
    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-quit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func marker(in dir: URL) -> URL { dir.appendingPathComponent("tabs-restored") }

    /// A session that blocks nothing, so no browser is ever asked.
    private let quietPlan = SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: [])

    @Test func aResumedSessionQuietsItsFirstSweep() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FocusController(directory: dir)
        first.start()
        first.start(quietPlan)
        first.stop(restoringTabs: true)
        // As quitting leaves it when it put tabs back.
        FileManager.default.createFile(atPath: marker(in: dir).path, contents: Data())

        let second = FocusController(directory: dir)
        second.start()
        defer { second.stop() }
        #expect(second.engine.session != nil)
        #expect(second.quietsNextSweep)
        #expect(!FileManager.default.fileExists(atPath: marker(in: dir).path), "the marker is used once")
    }

    @Test func withoutASessionTheMarkerIsJustCleared() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: marker(in: dir).path, contents: Data())
        let controller = FocusController(directory: dir)
        controller.start()
        defer { controller.stop() }
        #expect(!controller.quietsNextSweep)
        #expect(!FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    @Test func quittingWithNothingOnTheBlockPageLeavesNoMarker() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.start()
        controller.start(quietPlan)
        // It blocks no websites, so there is nothing to put back.
        controller.stop(restoringTabs: true)
        #expect(!FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    @Test func aPlainStartIsNotQuiet() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.start()
        defer { controller.stop() }
        #expect(!controller.quietsNextSweep)
    }
}
