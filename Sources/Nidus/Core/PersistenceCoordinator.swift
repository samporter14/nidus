// Ordered local persistence. The UI changes in memory immediately; immutable
// snapshots are encoded and written on a utility queue. One pending snapshot
// per file replaces earlier pending snapshots, including pending deletions.
// A deletion and a write in flight use the same queue, so Clear cannot be
// undone by an older save finishing later.

import Combine
import Foundation

struct PersistenceFailure: Equatable, Sendable, Identifiable {
    let url: URL
    let label: String
    let message: String
    var id: URL { url }
}

/// Shared by the production stores. A standalone store without a coordinator
/// retains its immediate-write contract for import tools and existing tests.
/// Production shutdown must await flush() before accepting termination.
@MainActor
final class PersistenceCoordinator: ObservableObject {
    @Published private(set) var failures: [PersistenceFailure] = []
    private var appliedVersion: UInt64 = 0
    private let perform: OrderedFileWriter.Perform
    private lazy var writer = OrderedFileWriter(perform: perform) { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.apply(snapshot) }
    }

    init(perform: @escaping OrderedFileWriter.Perform = OrderedFileWriter.writeAtomically) {
        self.perform = perform
    }

    func write(to url: URL, label: String, encode: @escaping @Sendable () throws -> Data) {
        writer.enqueue(url: url, label: label, encode: encode)
    }

    func remove(_ url: URL, label: String) {
        writer.enqueue(url: url, label: label, encode: { nil })
    }

    func retryFailedWrites() { writer.retry() }

    /// Current state, rather than the snapshot returned by an earlier flush.
    /// Check immediately before replying to termination, with no intervening
    /// await: another main-actor producer may have queued an edit while the
    /// flush continuation was waiting to resume.
    var isDurable: Bool { writer.isDurable }

    /// Drains queued encoding, writes, and deletions without blocking the main
    /// actor. False means the newest desired contents of a file are not durable.
    func flush() async -> Bool {
        let snapshot = await withCheckedContinuation { continuation in
            writer.flush { continuation.resume(returning: $0) }
        }
        apply(snapshot)
        return snapshot.failures.isEmpty
    }

    private func apply(_ snapshot: OrderedFileWriter.Snapshot) {
        guard snapshot.version >= appliedVersion else { return }
        appliedVersion = snapshot.version
        if failures != snapshot.failures { failures = snapshot.failures }
    }
}

/// Lock protects every mutable field; encoding and file access run only on
/// queue. No callback is invoked under the lock. The queue owns an active
/// drain until all work is completed, even if a caller releases its store.
final class OrderedFileWriter: @unchecked Sendable {
    typealias Perform = @Sendable (URL, Data?) throws -> Void
    struct Snapshot: Sendable {
        let version: UInt64
        let failures: [PersistenceFailure]
    }
    private struct Request: Sendable {
        let revision: UInt64
        let url: URL
        let label: String
        let encode: @Sendable () throws -> Data?
    }

    private let queue = DispatchQueue(label: "local.sam.nidus.persistence", qos: .utility)
    private let lock = NSLock()
    private let perform: Perform
    private let onStatus: @Sendable (Snapshot) -> Void
    private var revision: UInt64 = 0
    private var statusVersion: UInt64 = 0
    private var latest: [URL: UInt64] = [:]
    private var pending: [URL: Request] = [:]
    private var order: [URL] = []
    private var running = false
    private var failedRequests: [URL: Request] = [:]
    private var failures: [URL: PersistenceFailure] = [:]
    private var waiters: [@Sendable (Snapshot) -> Void] = []

    init(perform: @escaping Perform, onStatus: @escaping @Sendable (Snapshot) -> Void) {
        self.perform = perform
        self.onStatus = onStatus
    }

    static func writeAtomically(_ url: URL, _ data: Data?) throws {
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func enqueue(url: URL, label: String, encode: @escaping @Sendable () throws -> Data?) {
        lock.lock()
        revision &+= 1
        let request = Request(revision: revision, url: url, label: label, encode: encode)
        latest[url] = request.revision
        // An old failed snapshot must never be retried over a newer edit.
        failedRequests.removeValue(forKey: url)
        if pending[url] == nil { order.append(url) }
        pending[url] = request
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func retry() {
        lock.lock()
        // Retry only current failures that have no newer edit pending. Enqueue
        // while locked so a concurrent new edit cannot be overtaken by retry.
        for request in failedRequests.values.sorted(by: { $0.revision < $1.revision }) {
            guard latest[request.url] == request.revision, pending[request.url] == nil else { continue }
            order.append(request.url)
            pending[request.url] = request
        }
        failedRequests.removeAll()
        let start = !running && !order.isEmpty
        if start { running = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func flush(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        lock.lock()
        if running {
            waiters.append(completion)
            lock.unlock()
        } else {
            let snapshot = snapshotLocked()
            lock.unlock()
            completion(snapshot)
        }
    }

    var isDurable: Bool {
        lock.withLock { !running && pending.isEmpty && order.isEmpty && failures.isEmpty }
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(version: statusVersion, failures: failures.values.sorted { $0.url.path < $1.url.path })
    }

    private func drain() {
        while true {
            lock.lock()
            guard !order.isEmpty else {
                running = false
                let callbacks = waiters
                waiters.removeAll()
                let snapshot = snapshotLocked()
                lock.unlock()
                callbacks.forEach { $0(snapshot) }
                return
            }
            let url = order.removeFirst()
            let request = pending.removeValue(forKey: url)!
            lock.unlock()

            let failure: PersistenceFailure?
            do {
                try perform(request.url, request.encode())
                failure = nil
            } catch {
                failure = PersistenceFailure(url: request.url, label: request.label, message: error.localizedDescription)
            }

            lock.lock()
            if latest[url] == request.revision {
                statusVersion &+= 1
                if let failure {
                    failures[url] = failure
                    failedRequests[url] = request
                } else {
                    failures.removeValue(forKey: url)
                    failedRequests.removeValue(forKey: url)
                }
            }
            let snapshot = snapshotLocked()
            lock.unlock()
            onStatus(snapshot)
        }
    }
}
