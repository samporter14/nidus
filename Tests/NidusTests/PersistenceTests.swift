import Foundation
import Testing
@testable import Nidus

@MainActor
struct AsyncPersistenceTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nidus-persistence-\(UUID().uuidString)")
    }

    @Test func productionStoresRoundTripAndClearAfterFlushing() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceCoordinator()
        #expect(persistence.isDurable)
        let historyURL = directory.appendingPathComponent("history.json")
        let notesURL = directory.appendingPathComponent(ResumeNoteStore.fileName)
        let sessionURL = directory.appendingPathComponent("session.json")
        let history = FocusHistory(url: historyURL, persistence: persistence)
        let inbox = FocusInbox(directory: directory, persistence: persistence)
        let notes = ResumeNoteStore(url: notesURL, persistence: persistence)
        let session = FileSessionStore(url: sessionURL, persistence: persistence)
        history.append(StatsTests.entry(-1, minutes: 25))
        history.append(StatsTests.entry(0, minutes: 45))
        inbox.add(text: "Read this later", link: "https://example.org/paper")
        let note = ResumeNote(text: "Revise the legend")
        notes.add(note)
        notes.update(note.id) { $0.text = "Revise Figure 3" }
        session.save(SessionRecord(lastPlan: plan(45)))

        #expect(await persistence.flush())
        #expect(FocusHistory(url: historyURL).sessions == history.sessions)
        #expect(FocusInbox(directory: directory).items == inbox.items)
        #expect(ResumeNoteStore(url: notesURL).notes == notes.notes)
        #expect(FileSessionStore(url: sessionURL).load()?.lastPlan == plan(45))

        history.clear()
        inbox.clear()
        notes.clear()
        #expect(await persistence.flush())
        for url in [historyURL, inbox.url, notesURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(persistence.failures.isEmpty)
        #expect(persistence.isDurable)
    }

    @Test func rapidEditsEncodeOnlyNewestPendingSnapshotOffMainThread() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let persistence = PersistenceCoordinator()
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let observations = PersistenceProbe()
        persistence.write(to: url, label: "Test") {
            observations.encoded(onMain: Thread.isMainThread)
            started.continuation.yield(())
            _ = release.wait(timeout: .now() + 5)
            return Data("old".utf8)
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        for index in 0..<100 {
            persistence.write(to: url, label: "Test") {
                observations.encoded(onMain: Thread.isMainThread)
                return Data("revision-\(index)".utf8)
            }
        }
        release.signal()
        #expect(await persistence.flush())
        #expect(try String(contentsOf: url, encoding: .utf8) == "revision-99")
        #expect(observations.encodeCount == 2)
        #expect(!observations.encodedOnMain)
    }

    @Test func clearCannotBeResurrectedByAnOlderInFlightWrite() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let persistence = PersistenceCoordinator()
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        persistence.write(to: url, label: "Test") {
            started.continuation.yield(())
            _ = release.wait(timeout: .now() + 5)
            return Data("must disappear".utf8)
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        persistence.write(to: url, label: "Test") { Data("also obsolete".utf8) }
        persistence.remove(url, label: "Test")
        release.signal()
        #expect(await persistence.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        persistence.retryFailedWrites()
        #expect(await persistence.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path))

        persistence.write(to: url, label: "Test") { Data("new after clear".utf8) }
        #expect(await persistence.flush())
        #expect(try String(contentsOf: url, encoding: .utf8) == "new after clear")
    }

    @Test func failedWritesStayVisibleAndRetryTheNewestDesiredContents() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let probe = PersistenceProbe()
        probe.shouldFail = true
        let persistence = PersistenceCoordinator { url, data in
            if probe.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try OrderedFileWriter.writeAtomically(url, data)
        }
        persistence.write(to: url, label: "Inbox") { Data("first".utf8) }
        #expect(!(await persistence.flush()))
        #expect(!persistence.isDurable)
        #expect(persistence.failures.map(\.label) == ["Inbox"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        persistence.write(to: url, label: "Inbox") { Data("latest".utf8) }
        #expect(!(await persistence.flush()))
        probe.shouldFail = false
        persistence.retryFailedWrites()
        #expect(await persistence.flush())
        #expect(persistence.failures.isEmpty)
        #expect(persistence.isDurable)
        #expect(try String(contentsOf: url, encoding: .utf8) == "latest")
    }

    @Test func retryAfterFailedClearDeletesInsteadOfRestoringOldContents() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let probe = PersistenceProbe()
        let persistence = PersistenceCoordinator { url, data in
            if probe.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try OrderedFileWriter.writeAtomically(url, data)
        }
        persistence.write(to: url, label: "History") { Data("old history".utf8) }
        #expect(await persistence.flush())
        probe.shouldFail = true
        persistence.remove(url, label: "History")
        #expect(!(await persistence.flush()))
        #expect(persistence.failures.count == 1)
        probe.shouldFail = false
        persistence.retryFailedWrites()
        #expect(await persistence.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func replacingAFailedWriteWithClearDoesNotRetryTheOldSnapshot() async {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let probe = PersistenceProbe()
        probe.shouldFail = true
        let persistence = PersistenceCoordinator { url, data in
            if probe.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try OrderedFileWriter.writeAtomically(url, data)
        }
        persistence.write(to: url, label: "History") { Data("never restore".utf8) }
        #expect(!(await persistence.flush()))
        probe.shouldFail = false
        persistence.remove(url, label: "History")
        persistence.retryFailedWrites()
        #expect(await persistence.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unchangedPausedCheckpointsDoNotWriteAgain() {
        let clock = TestClock()
        let store = CountingSessionStore()
        let engine = SessionEngine(store: store, now: { clock.now })
        engine.start(plan(25))
        clock.advance(60)
        engine.pause()
        engine.checkpoint()
        let before = store.saves
        clock.advance(60)
        engine.checkpoint()
        engine.checkpoint()
        #expect(store.saves == before)
        engine.resume()
        clock.advance(15)
        engine.checkpoint()
        #expect(store.saves > before)
        #expect(store.record?.session?.seenElapsed == 75)
    }

    @Test func successfulFlushDoesNotDeclareALaterPendingEditDurable() async {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceCoordinator()
        let earlierFlush = await persistence.flush()
        #expect(earlierFlush && persistence.isDurable)
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        persistence.write(to: directory.appendingPathComponent("latest.json"), label: "Test") {
            started.continuation.yield(())
            _ = release.wait(timeout: .now() + 5)
            return Data("new edit".utf8)
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        #expect(earlierFlush)
        #expect(!persistence.isDurable, "A previous successful flush cannot authorize quit after another edit")
        release.signal()
        #expect(await persistence.flush())
        #expect(persistence.isDurable)
    }
}

private final class PersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    private var count = 0
    private var main = false
    var shouldFail: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var encodeCount: Int { lock.withLock { count } }
    var encodedOnMain: Bool { lock.withLock { main } }
    func encoded(onMain: Bool) { lock.withLock { count += 1; main = main || onMain } }
}

@MainActor
private final class CountingSessionStore: SessionStore {
    var record: SessionRecord?
    var saves = 0
    func load() -> SessionRecord? { record }
    func save(_ record: SessionRecord) { self.record = record; saves += 1 }
}
