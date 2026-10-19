import Foundation
import Testing
@testable import Nidus

struct BrickCompanionTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T14:30:00Z")!

    private func signal(id: String = "20261019-314159", at date: Date? = nil) -> BrickSignal {
        BrickSignal(version: 1, id: id,
                    timestamp: ISO8601DateFormatter().string(from: date ?? now),
                    event: BrickSignal.kind)
    }

    @Test func fileAndLinkUseTheSameEvent() throws {
        let event = signal()
        let data = try JSONEncoder().encode(event)
        #expect(BrickSignal.parse(data) == event)
        let url = try #require(URL(string: "nidus://brick?id=20261019-314159&timestamp=2026-10-19T14%3A30%3A00Z"))
        #expect(BrickSignal.parse(url) == event)
        #expect(event.disposition(at: now, ledger: .init(), idle: true) == .offer)
    }

    @Test func malformedAndOversizedRequestsAreRejected() throws {
        #expect(BrickSignal.parse(Data(repeating: 65, count: 4097)) == nil)
        #expect(BrickSignal.parse(Data("{}".utf8)) == nil)
        #expect(BrickSignal.parse(URL(string: "nidus://brick?id=short&timestamp=2026-10-19T14%3A30%3A00Z&id=duplicate")!) == nil)
        #expect(!signal(id: "bad id!").isValid(at: now))
        #expect(!BrickSignal(version: 2, id: "20261019-314159", timestamp: signal().timestamp,
                             event: BrickSignal.kind).isValid(at: now))
        #expect(!BrickSignal(version: 1, id: "20261019-314159", timestamp: signal().timestamp,
                             event: "phone_bricked").isValid(at: now))
    }

    @Test func staleFutureAndReplayedEventsDoNotOffer() {
        #expect(signal(at: now.addingTimeInterval(-120)).disposition(at: now, ledger: .init(), idle: true) == .offer)
        #expect(signal(at: now.addingTimeInterval(-121)).disposition(at: now, ledger: .init(), idle: true) == .ignore)
        #expect(signal(at: now.addingTimeInterval(15)).disposition(at: now, ledger: .init(), idle: true) == .offer)
        #expect(signal(at: now.addingTimeInterval(16)).disposition(at: now, ledger: .init(), idle: true) == .ignore)
        var ledger = BrickReplayLedger()
        let event = signal()
        ledger.record(event, now: now) // Current file is consumed as the baseline.
        #expect(event.disposition(at: now, ledger: ledger, idle: true) == .ignore)
        #expect(signal(id: "20261019-271828").disposition(at: now, ledger: ledger, idle: false) == .consume)
        ledger.record(signal(id: "20261019-271828"), now: now)
        #expect(signal(id: "20261019-271828").disposition(at: now, ledger: ledger, idle: true) == .ignore)
    }

    @Test func setupAcceptsAnExpiredBaselineButNotMalformedSignalStructure() {
        let expired = signal(at: now.addingTimeInterval(-3600))
        #expect(expired.hasValidStructure)
        #expect(!expired.isValid(at: now))
        #expect(!signal(id: "short").hasValidStructure)
        #expect(!BrickSignal(version: 1, id: "request-1234", timestamp: "not-a-date",
                             event: BrickSignal.kind).hasValidStructure)
        #expect(!BrickSignal(version: 1, id: "request-1234", timestamp: signal().timestamp,
                             event: "phone_bricked").hasValidStructure)
    }

    @Test func fractionalTimeAndTimezoneOffsetAreAccepted() {
        let fractional = BrickSignal(version: 1, id: "request-1234", timestamp: "2026-10-19T14:29:59.500Z",
                                     event: BrickSignal.kind)
        let offset = BrickSignal(version: 1, id: "request-5678", timestamp: "2026-10-19T10:30:00-04:00",
                                 event: BrickSignal.kind)
        #expect(fractional.isValid(at: now))
        #expect(offset.isValid(at: now))
    }

    @Test func unbrickClearsOnlyTheOfferEvenWhenMacIsBusy() throws {
        let cleared = BrickSignal(version: 1, id: "clear-123456", timestamp: signal().timestamp,
                                  event: BrickSignal.clearedKind)
        #expect(BrickSignal.parse(try JSONEncoder().encode(cleared)) == cleared)
        #expect(cleared.disposition(at: now, ledger: .init(), idle: true) == .clear)
        #expect(cleared.disposition(at: now, ledger: .init(), idle: false) == .clear)
    }

    @Test func unbrickSuppressesDelayedRequestsAndAllowsALaterBrick() {
        let cleared = BrickSignal(version: 1, id: "clear-123456", timestamp: signal().timestamp,
                                  event: BrickSignal.clearedKind)
        var ledger = BrickReplayLedger()
        ledger.record(cleared, now: now)
        #expect(signal(at: now.addingTimeInterval(-1)).disposition(at: now, ledger: ledger, idle: true) == .ignore)
        #expect(signal().disposition(at: now, ledger: ledger, idle: true) == .ignore)
        #expect(cleared.disposition(at: now, ledger: ledger, idle: true) == .ignore)
        #expect(signal(at: now.addingTimeInterval(1)).disposition(at: now, ledger: ledger, idle: true) == .offer)
    }

    @Test func delayedUnbrickCannotClearANewerRequest() {
        var ledger = BrickReplayLedger()
        ledger.record(signal(), now: now)
        let old = BrickSignal(version: 1, id: "clear-123456",
                              timestamp: signal(at: now.addingTimeInterval(-1)).timestamp,
                              event: BrickSignal.clearedKind)
        #expect(old.disposition(at: now, ledger: ledger, idle: true) == .ignore)
        let expired = BrickSignal(version: 1, id: "clear-654321",
                                  timestamp: signal(at: now.addingTimeInterval(-121)).timestamp,
                                  event: BrickSignal.clearedKind)
        #expect(expired.disposition(at: now, ledger: ledger, idle: true) == .ignore)
    }

    @Test func choosingAnOfferOnlyOpensTheComposerAndNeedsNoSavedSetup() {
        let pending = BrickPendingOffer(signal: signal())
        var composerOpenCount = 0
        #expect(pending.chooseSession(at: now, enabled: true, idle: true, openComposer: { composerOpenCount += 1 }))
        #expect(composerOpenCount == 1)
        // A valid Brick request makes the same choice available when there
        // are no saved setups; this action has no session-start callback.
        #expect(signal().disposition(at: now, ledger: .init(), idle: true) == .offer)
    }

    @Test func disabledBusyAndExpiredOffersCannotOpenTheComposer() {
        let pending = BrickPendingOffer(signal: signal())
        var composerOpenCount = 0
        #expect(!pending.chooseSession(at: now, enabled: false, idle: true, openComposer: { composerOpenCount += 1 }))
        #expect(!pending.chooseSession(at: now, enabled: true, idle: false, openComposer: { composerOpenCount += 1 }))
        #expect(!pending.chooseSession(at: now.addingTimeInterval(121), enabled: true, idle: true,
                                       openComposer: { composerOpenCount += 1 }))
        #expect(composerOpenCount == 0)
    }

    @Test func floodedLedgerKeepsAReplayFloor() {
        var ledger = BrickReplayLedger()
        for index in 0...4096 {
            ledger.record(signal(id: "request-\(index + 100000)"), now: now)
        }
        #expect(ledger.entries.count == 4096)
        #expect(signal(id: "request-100000").disposition(at: now, ledger: ledger, idle: true) == .ignore)
    }

    @Test func temporaryFileReadIsBoundedAndReportsInvalidData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-brick-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url)
        let initial = BrickFileReader.readFile(at: url)
        #expect(initial.data == Data("{}".utf8))
        #expect(initial.status.contains("valid JSON"))
        try Data(repeating: 65, count: 100_000).write(to: url)
        let oversized = BrickFileReader.readFile(at: url)
        #expect(oversized.data == nil)
        #expect(oversized.status.contains("4 KB"))
        try JSONEncoder().encode(signal()).write(to: url)
        let valid = BrickFileReader.readFile(at: url)
        #expect(valid.data.flatMap(BrickSignal.parse) == signal())
    }

    @Test func selectedFileBaselineAndWhitespaceReplayStayConsumed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-brick-gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = signal()
        let second = signal(id: "20261019-271828")
        try JSONEncoder().encode(first).write(to: url)
        var gate = BrickFileGate()
        var ledger = BrickReplayLedger()
        guard case .baseline(let baseline?) = gate.ingest(try #require(BrickFileReader.readFile(at: url).data)) else {
            Issue.record("Existing file must be the ignored baseline")
            return
        }
        ledger.record(baseline, now: now)
        #expect(first.disposition(at: now, ledger: ledger, idle: true) == .ignore)

        let reformatted = "{ \"event\": \"phone_focus_requested\", \"timestamp\": \"\(first.timestamp)\", \"id\": \"\(first.id)\", \"version\": 1 }"
        try Data(reformatted.utf8).write(to: url)
        guard case .changed(let replay?) = gate.ingest(try #require(BrickFileReader.readFile(at: url).data)) else {
            Issue.record("Changed bytes should be read")
            return
        }
        #expect(replay.disposition(at: now, ledger: ledger, idle: true) == .ignore)
        #expect(gate.ingest(try #require(BrickFileReader.readFile(at: url).data)) == .unchanged)

        try JSONEncoder().encode(second).write(to: url)
        guard case .changed(let fresh?) = gate.ingest(try #require(BrickFileReader.readFile(at: url).data)) else {
            Issue.record("A new request should be read")
            return
        }
        #expect(fresh.disposition(at: now, ledger: ledger, idle: true) == .offer)
        gate.reset() // Relaunch or choosing the file again establishes a new baseline.
        #expect(gate.ingest(try #require(BrickFileReader.readFile(at: url).data)) == .baseline(second))
    }

    @Test func scopedBookmarkSurvivesAtomicOverwriteWhenBookmarkServiceIsAvailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-brick-atomic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url)
        // The restricted test runner cannot reach ScopedBookmarksAgent. On a
        // normal macOS runner this exercises the actual selected-file path.
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let initial = BrickFileReader.read(bookmark: bookmark)
        #expect(initial.data == Data("{}".utf8))
        try JSONEncoder().encode(signal()).write(to: url, options: .atomic)
        let replaced = BrickFileReader.read(bookmark: bookmark)
        #expect(replaced.data.flatMap(BrickSignal.parse) == signal())
        #expect(replaced.refreshedBookmark != nil)
    }
}
