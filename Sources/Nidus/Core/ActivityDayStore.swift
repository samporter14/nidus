//
//  ActivityDayStore.swift
//  Nidus
//
//  The folder of day files. Encoding and every file change run off the main
//  actor, in the order they were asked for, so a save made before a clear
//  cannot bring the cleared day back. As in HistoryFileWriter, a burst of
//  saves keeps only the newest state of each day.
//

import Foundation
import os

final class ActivityDayStore: @unchecked Sendable {
    enum Change: Sendable, Equatable {
        case write(ActivityDayLog)
        case clear
        case removeTitles
        /// Deletes day files before this key.
        case prune(before: String)
    }

    let directory: URL
    private let queue = DispatchQueue(label: "local.sam.nidus.activity-days", qos: .utility)
    private let lock = NSLock()
    private var pending: [Change] = []
    private var isDraining = false
    private let perform: (@Sendable (Change) -> Void)?

    /// `perform` replaces the file work, so tests can hold a write in progress.
    init(directory: URL, perform: (@Sendable (Change) -> Void)? = nil) {
        self.directory = directory
        self.perform = perform
    }

    func enqueue(_ change: Change) {
        lock.lock()
        if case .clear = change { pending.removeAll() }
        if case .write(let log) = change, let index = replaceableWrite(for: log.day) {
            pending[index] = change
        } else {
            pending.append(change)
        }
        if !isDraining {
            isDraining = true
            queue.async { self.drain() }
        }
        lock.unlock()
    }

    /// A pending write to the same day, with nothing after it that must
    /// happen between the two.
    private func replaceableWrite(for day: String) -> Int? {
        for index in pending.indices.reversed() {
            guard case .write(let log) = pending[index] else { return nil }
            if log.day == day { return index }
        }
        return nil
    }

    func flush() { queue.sync {} }

    private func drain() {
        while true {
            let next: Change? = lock.withLock {
                guard !pending.isEmpty else {
                    isDraining = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let next else { return }
            if let perform { perform(next) } else { apply(next) }
        }
    }

    // MARK: Reading

    /// Waits for accepted changes. Quick, but for the main actor only where
    /// one small file is wanted at once.
    func load(day: String) -> ActivityDayLog? {
        queue.sync { Self.read(url(for: day)) }
    }

    /// The days that have files, oldest first.
    func load(days: [String]) async -> [ActivityDayLog] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: days.sorted().compactMap { Self.read(url(for: $0)) })
            }
        }
    }

    /// Every saved day, oldest first.
    func loadAll() async -> [ActivityDayLog] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: dayKeys().compactMap { Self.read(url(for: $0)) })
            }
        }
    }

    /// Whether any day file still holds a name.
    func hasTitles() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: dayKeys().contains { Self.read(url(for: $0))?.hasTitles == true })
            }
        }
    }

    // MARK: Files

    func url(for day: String) -> URL { directory.appendingPathComponent(day + ".json") }

    /// Only names this store writes: anything else in the folder is left alone.
    private func dayKeys() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let key = String(name.dropLast(5))
            return Self.isDayKey(key) ? key : nil
        }.sorted()
    }

    static func isDayKey(_ key: String) -> Bool {
        key.utf8.count == 10 && key.utf8.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == 0x2D : (byte >= 0x30 && byte <= 0x39)
        }
    }

    static func encode(_ log: ActivityDayLog) throws -> Data { try JSONEncoder().encode(log) }

    private static func read(_ url: URL) -> ActivityDayLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(ActivityDayLog.self, from: data).sanitized }
        catch {
            logger.error("Could not read a day of activity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let logger = Logger(subsystem: "local.sam.nidus", category: "activity")

    private func apply(_ change: Change) {
        do {
            switch change {
            case .write(let log):
                try save(log)
            case .clear:
                for key in dayKeys() { try delete(key) }
            case .removeTitles:
                try rewrite { $0.hasTitles ? $0.removeTitles() : () }
            case .prune(let before):
                for key in dayKeys() where key < before { try delete(key) }
            }
        } catch {
            Self.logger.error("Could not save activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewrite(_ edit: (inout ActivityDayLog) -> Void) throws {
        for key in dayKeys() {
            guard var log = Self.read(url(for: key)) else { continue }
            let before = log
            edit(&log)
            if log == before { continue }
            if log.isEmpty { try delete(key) } else { try save(log) }
        }
    }

    private func save(_ log: ActivityDayLog) throws {
        let data = try Self.encode(log)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = url(for: log.day)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func delete(_ key: String) throws {
        do { try FileManager.default.removeItem(at: url(for: key)) }
        catch CocoaError.fileNoSuchFile { }
    }
}
