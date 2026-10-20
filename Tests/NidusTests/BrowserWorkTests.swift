import Foundation
import Testing
@testable import Nidus

struct BrowserWorkPolicyTests {
    @Test func quietPlansNeedNoBrowserWork() {
        var ledger = BrowserRestorationLedger()
        let quiet = Enforcement(mode: .block, apps: [], websites: [])
        let quietNeedsRestore = ledger.transition(from: nil, to: quiet)
        #expect(!quietNeedsRestore)
        #expect(!ledger.needsShutdownRestore(enforcement: quiet))
        let blocking = Enforcement(mode: .block, apps: [], websites: ["example.com"])
        let disabledNeedsRestore = ledger.transition(from: blocking, to: quiet, disabled: true)
        #expect(!disabledNeedsRestore)
        #expect(ledger.pending.isEmpty)
    }

    @Test func failureBackoffIsBoundedAndSuccessCanResetIt() {
        let now = Date(timeIntervalSince1970: 100)
        var retry = BrowserRetryPolicy()
        #expect(retry.nextAttempt <= now)
        for expectedDelay in [2.0, 4, 8, 16, 30, 30] {
            retry.recordFailure(at: now)
            #expect(retry.nextAttempt.timeIntervalSince(now) == expectedDelay)
        }
        retry.reset()
        #expect(retry.failures == 0)
        #expect(retry.nextAttempt <= now)
    }

    @Test func cancellationAndExpiredBudgetsForbidTheNextEvent() {
        let permit = BrowserWorkPermit()
        #expect(permit.timeout(maximum: 2) == 2)
        permit.cancel()
        #expect(permit.timeout(maximum: 2) == nil)
        let expired = BrowserWorkPermit(deadline: ProcessInfo.processInfo.systemUptime - 1)
        #expect(expired.timeout(maximum: 2) == nil)
        let bounded = BrowserWorkPermit(deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        #expect((bounded.timeout(maximum: 2) ?? 0) <= 0.5)
    }
}

@MainActor
struct BrowserWorkPoolTests {
    /// End's restoration can still be waiting when Start or Quit arrives.
    /// The new request must inherit that obligation even with no active rule.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func pendingEndRestoreSurvivesStartOrQuit(quitting: Bool) async {
        let pool = BrowserWorkPool()
        var ledger = BrowserRestorationLedger()
        let blocking = Enforcement(mode: .block, apps: [], websites: ["example.com"])
        let endedNeedsRestore = ledger.transition(from: blocking, to: nil)
        #expect(endedNeedsRestore)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let (started, began) = AsyncStream<Void>.makeStream()
        let (completed, finished) = AsyncStream<Bool>.makeStream()
        let tab = FakeBlockedTab()
        pool.submit(.safari, replacing: true) { permit in
            began.yield(())
            release.wait()
            if !permit.isCancelled { tab.restore() }
            return .success(BrowserWorkResult())
        } completion: { _ in }
        var startup = started.makeAsyncIterator()
        _ = await startup.next()

        let restore: Bool
        if quitting {
            restore = ledger.needsShutdownRestore(enforcement: nil)
        } else {
            restore = ledger.transition(from: nil, to: Enforcement(mode: .block, apps: [], websites: []))
        }
        #expect(restore)
        pool.invalidate()
        pool.submit(.safari, replacing: true) { _ in
            if restore { tab.restore() }
            return .success(BrowserWorkResult())
        } completion: { _ in finished.yield(tab.isRestored) }
        release.signal()
        var outcomes = completed.makeAsyncIterator()
        #expect(await outcomes.next() == true)
        ledger.didRestore(BrowserProfile.safari.bundleID)
        #expect(!ledger.pending.contains(BrowserProfile.safari.bundleID))
        began.finish()
        finished.finish()
    }

    /// No browser is contacted: Safari's fake job waits on a test-owned gate,
    /// while Chrome must still complete, then only the newest Safari plan runs.
    @Test(.timeLimit(.minutes(1)))
    func aSlowBrowserDoesNotBlockOthersAndObsoletePlansDoNotComplete() async {
        let pool = BrowserWorkPool()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let (started, began) = AsyncStream<Void>.makeStream()
        let (completed, finished) = AsyncStream<String>.makeStream()
        var staleCompletions = 0
        pool.submit(.safari) { permit in
            began.yield(())
            release.wait()
            return .success(BrowserWorkResult(redirected: permit.isCancelled ? [] : ["stale"]))
        } completion: { _ in staleCompletions += 1 }
        var startup = started.makeAsyncIterator()
        _ = await startup.next()

        pool.submit(.chrome) { _ in
            .success(BrowserWorkResult(redirected: ["chrome"]))
        } completion: { result in
            if case .success(let value) = result { finished.yield(value.redirected[0]) }
        }
        var outcomes = completed.makeAsyncIterator()
        #expect(await outcomes.next() == "chrome")

        pool.invalidate()
        pool.submit(.safari, replacing: true) { _ in
            .success(BrowserWorkResult(redirected: ["superseded"]))
        } completion: { _ in staleCompletions += 1 }
        pool.submit(.safari, replacing: true) { _ in
            .success(BrowserWorkResult(redirected: ["latest"]))
        } completion: { result in
            if case .success(let value) = result { finished.yield(value.redirected[0]) }
        }
        release.signal()
        #expect(await outcomes.next() == "latest")
        #expect(staleCompletions == 0)
        began.finish()
        finished.finish()
    }
}

private final class FakeBlockedTab: @unchecked Sendable {
    private let lock = NSLock()
    private var restored = false
    func restore() {
        lock.lock()
        restored = true
        lock.unlock()
    }
    var isRestored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return restored
    }
}
