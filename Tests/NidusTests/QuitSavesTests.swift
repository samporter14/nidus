import Foundation
import Testing
@testable import Nidus

/// What Nidus does as it quits or the Mac powers off: the session that just
/// ended is written to disk before anything else, with nothing stopped.
@MainActor
@Suite("Saves on quit and power-off")
struct QuitSavesTests {
    @Test func flushPendingSavesWritesTheLastSessionWithoutStopping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        let entry = SessionEntry(start: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                 end: Date(timeIntervalSinceReferenceDate: 800_001_500),
                                 focused: 1500, planned: 1500, outcome: .completed, goal: "Just ended")
        controller.history.append(entry)
        controller.flushPendingSaves()
        let file = dir.appendingPathComponent("history.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(entry.id.uuidString))
        // Still usable: a later edit is written too.
        let next = SessionEntry(start: entry.end, end: entry.end.addingTimeInterval(600), focused: 600,
                                planned: 600, outcome: .completed, goal: "After")
        controller.history.append(next)
        controller.flushPendingSaves()
        #expect(try String(contentsOf: file, encoding: .utf8).contains(next.id.uuidString))
    }
}
