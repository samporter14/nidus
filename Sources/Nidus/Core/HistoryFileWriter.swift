//
//  HistoryFileWriter.swift
//  Nidus
//
//  Encoding and atomic replacement run off the main actor. A burst of edits
//  keeps only the newest pending state, plus the write already in progress.
//

import Foundation
import os

/// Mutable scheduling state is held under `lock`; file mutations run only
/// on `queue`. No worker calls back to the main actor, so shutdown can drain
/// it without deadlocking. The caller must not call `flush` from `perform`.
final class HistoryFileWriter: @unchecked Sendable {
    enum Mutation: Sendable {
        case write([SessionEntry])
        case remove
    }

    private let queue = DispatchQueue(label: "local.sam.nidus.history-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: Mutation?
    private var isDraining = false
    private let perform: @Sendable (Mutation) -> Void
    private let failure: Failure

    /// The latest write failed. Read anywhere; set on the queue.
    var lastWriteFailed: Bool { failure.value }

    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        var value: Bool { lock.withLock { failed } }
        func set(_ value: Bool) { lock.withLock { failed = value } }
    }

    init(url: URL) {
        let failure = Failure()
        self.failure = failure
        perform = { mutation in
            do {
                switch mutation {
                case .write(let sessions):
                    let data = try FocusHistory.encode(sessions)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                case .remove:
                    do { try FileManager.default.removeItem(at: url) }
                    catch CocoaError.fileNoSuchFile { }
                }
                failure.set(false)
            } catch {
                failure.set(true)
                Logger(subsystem: "local.sam.nidus", category: "history")
                    .error("Could not save history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Allows tests to hold a write in progress without depending on disk
    /// speed, and prove that edits stay responsive and pending state bounded.
    init(perform: @escaping @Sendable (Mutation) -> Void) {
        self.perform = perform
        failure = Failure()
    }

    func enqueue(_ mutation: Mutation) {
        lock.lock()
        pending = mutation
        if !isDraining {
            isDraining = true
            // Schedule while still holding the lock: flush cannot get ahead
            // of a mutation that has already been accepted.
            queue.async { self.drain() }
        }
        lock.unlock()
    }

    func flush() { queue.sync {} }

    private func drain() {
        while true {
            let next: Mutation? = lock.withLock {
                guard let next = pending else {
                    isDraining = false
                    return nil
                }
                pending = nil
                return next
            }
            guard let next else { return }
            perform(next)
        }
    }
}
