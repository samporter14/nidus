import Foundation
import Testing
@testable import Nidus

struct HistoryWriterTests {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UUID]?] = []
        private var usedMainThread = false

        func append(_ mutation: HistoryFileWriter.Mutation) {
            lock.withLock {
                usedMainThread = usedMainThread || Thread.isMainThread
                switch mutation {
                case .write(let sessions): stored.append(sessions.map(\.id))
                case .remove: stored.append(nil)
                }
            }
        }

        var mutations: [[UUID]?] { lock.withLock { stored } }
        var ranOnMainThread: Bool { lock.withLock { usedMainThread } }
    }

    private func entry(_ goal: String) -> SessionEntry {
        SessionEntry(start: Date(timeIntervalSinceReferenceDate: 800_000_000),
                     end: Date(timeIntervalSinceReferenceDate: 800_001_500),
                     focused: 1500, planned: 1500, outcome: .completed, goal: goal)
    }

    @Test func slowWriteDoesNotHoldUpEditsAndOnlyNewestPendingStateIsWritten() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let record = Record()
        let first = entry("First"), second = entry("Second"), latest = entry("Latest")
        let writer = HistoryFileWriter { mutation in
            if record.mutations.isEmpty {
                started.signal()
                // A bound makes a regression fail instead of hanging tests.
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            record.append(mutation)
        }
        writer.enqueue(.write([first]))
        #expect(started.wait(timeout: .now() + 5) == .success)
        writer.enqueue(.write([first, second]))
        writer.enqueue(.remove)
        writer.enqueue(.write([latest]))
        #expect(record.mutations.isEmpty, "the first write is still held while edits return")
        release.signal()
        writer.flush()
        #expect(record.mutations == [[first.id], [latest.id]], "intermediate snapshots are replaced")
        #expect(!record.ranOnMainThread)
    }

    @Test func clearFollowsAnyWriteAlreadyInProgress() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let record = Record()
        let first = entry("First"), second = entry("Second")
        let writer = HistoryFileWriter { mutation in
            if record.mutations.isEmpty {
                started.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            record.append(mutation)
        }
        writer.enqueue(.write([first]))
        #expect(started.wait(timeout: .now() + 5) == .success)
        writer.enqueue(.write([first, second]))
        writer.enqueue(.remove)
        release.signal()
        writer.flush()
        #expect(record.mutations == [[first.id], nil], "queued saves cannot recreate cleared history")
    }

    @MainActor
    @Test func editsAndClearPersistInOrderAndFlushMakesThemReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-writer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let history = FocusHistory(url: url)
        let first = entry("First"), second = entry("Second")
        history.append(first)
        history.append(second)
        #expect(history.setFinished(second.id, true))
        #expect(history.remove(first.id))
        history.flush()
        let loaded = FocusHistory(url: url)
        #expect(loaded.sessions.count == 1)
        #expect(loaded.sessions.first?.id == second.id)
        #expect(loaded.sessions.first?.finished == true)

        history.append(entry("Will be cleared"))
        history.clear()
        history.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FocusHistory(url: url).sessions.isEmpty)

        history.append(first)
        history.flush()
        #expect(FocusHistory(url: url).sessions == [first], "recording works again after clear")
    }
}
