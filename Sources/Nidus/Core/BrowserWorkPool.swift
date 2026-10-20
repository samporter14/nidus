import Foundation

/// Cancellation is checked between Apple Events. An event already sent cannot
/// be recalled, but a stale tab read must never be followed by a new redirect.
final class BrowserWorkPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval?

    init(deadline: TimeInterval? = nil) { self.deadline = deadline }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// A monotonic deadline also limits each individual blocking Apple Event.
    func timeout(maximum: TimeInterval) -> TimeInterval? {
        guard !isCancelled else { return nil }
        let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime } ?? maximum
        guard remaining > 0 else { return nil }
        return min(maximum, remaining)
    }
}

struct BrowserRetryPolicy {
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantPast

    mutating func recordFailure(at now: Date) {
        failures = min(failures + 1, 5)
        nextAttempt = now.addingTimeInterval(min(30, pow(2, Double(failures))))
    }

    mutating func reset() {
        failures = 0
        nextAttempt = .distantPast
    }
}

/// Tracks reconciliation independently of whether a session is currently
/// enforcing. End/Pause must not lose unfinished restores when Start or Quit
/// supersedes their pending worker jobs.
struct BrowserRestorationLedger {
    private(set) var pending: Set<String> = []

    mutating func transition(from old: Enforcement?, to new: Enforcement?, disabled: Bool = false) -> Bool {
        guard !disabled else { pending.removeAll(); return false }
        let needed = Self.hasWebsiteRules(old) || Self.hasWebsiteRules(new) || !pending.isEmpty
        if needed { pending = Set(BrowserProfile.known.map(\.bundleID)) }
        return needed
    }

    func needsShutdownRestore(enforcement: Enforcement?, disabled: Bool = false) -> Bool {
        !disabled && (Self.hasWebsiteRules(enforcement) || !pending.isEmpty)
    }

    mutating func didRestore(_ browserID: String) { pending.remove(browserID) }

    private static func hasWebsiteRules(_ rule: Enforcement?) -> Bool {
        guard let rule else { return false }
        return rule.mode != .block || !rule.websites.isEmpty
    }
}

struct BrowserWorkResult: Sendable {
    var redirected: [String] = []
    var restored = 0
}

/// One serial lane per supported browser: at most five concurrent operations,
/// and at most one replacement request waiting behind each in-flight request.
/// A stopped Safari therefore cannot hold Chrome's polling or restoration.
@MainActor
final class BrowserWorkPool {
    typealias Outcome = Result<BrowserWorkResult, AppleEventError>
    typealias Work = @Sendable (BrowserWorkPermit) -> Outcome
    typealias Completion = @MainActor @Sendable (Outcome) -> Void

    private struct Job: Sendable {
        let id = UUID()
        let generation: Int
        let permit: BrowserWorkPermit
        let work: Work
        let completion: Completion
    }

    private final class Lane {
        let queue: DispatchQueue
        var running: Job?
        var pending: Job?
        var retry = BrowserRetryPolicy()

        init(_ id: String) {
            queue = DispatchQueue(label: "focus.browser.\(id)", qos: .utility)
        }
    }

    private var generation = 0
    private var lanes: [String: Lane] = [:]

    /// State transitions supersede both old rules and their retry delay.
    func invalidate() {
        generation += 1
        for lane in lanes.values {
            lane.running?.permit.cancel()
            lane.pending?.permit.cancel()
            lane.pending = nil
            lane.retry.reset()
        }
    }

    @discardableResult
    func submit(_ browser: BrowserProfile, replacing: Bool = false,
                deadline: TimeInterval? = nil, now: Date = Date(),
                work: @escaping Work, completion: @escaping Completion) -> Bool {
        // The pool is bounded by the app's explicitly supported profiles.
        guard BrowserProfile.known.contains(browser) else { return false }
        let lane = lanes[browser.bundleID] ?? Lane(browser.bundleID)
        lanes[browser.bundleID] = lane
        guard replacing || (lane.running == nil && now >= lane.retry.nextAttempt) else { return false }
        let job = Job(generation: generation, permit: BrowserWorkPermit(deadline: deadline),
                      work: work, completion: completion)
        if lane.running != nil {
            lane.running?.permit.cancel()
            lane.pending?.permit.cancel()
            lane.pending = job
        } else {
            run(job, in: lane, browserID: browser.bundleID)
        }
        return true
    }

    private func run(_ job: Job, in lane: Lane, browserID: String) {
        lane.running = job
        lane.queue.async { [weak self] in
            let result: Outcome = job.permit.isCancelled ? .success(BrowserWorkResult()) : job.work(job.permit)
            Task { @MainActor [weak self] in
                self?.finished(job, result: result, browserID: browserID)
            }
        }
    }

    private func finished(_ job: Job, result: Outcome, browserID: String) {
        guard let lane = lanes[browserID], lane.running?.id == job.id else { return }
        lane.running = nil
        if job.generation == generation, !job.permit.isCancelled {
            switch result {
            case .success: lane.retry.reset()
            case .failure: lane.retry.recordFailure(at: Date())
            }
            job.completion(result)
        }
        if let next = lane.pending {
            lane.pending = nil
            if next.generation == generation, !next.permit.isCancelled {
                run(next, in: lane, browserID: browserID)
            }
        }
    }
}
