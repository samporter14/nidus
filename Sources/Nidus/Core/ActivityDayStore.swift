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

    /// What is on disk for a day. A file that is there but can't be read is
    /// never the same as no file: treating it as an empty day would let the
    /// next save write over it.
    enum DayFile: Sendable, Equatable {
        case absent
        case loaded(ActivityDayLog)
        /// There, but not a day this store can decode. Set aside before the
        /// day is written again.
        case corrupt
        /// There, but it could not be read (permissions, a disk error). Never
        /// written over.
        case inaccessible

        var log: ActivityDayLog? {
            if case .loaded(let log) = self { return log }
            return nil
        }
    }

    /// How a change went on disk. `day` is set for a write.
    struct Outcome: Sendable, Equatable {
        var day: String?
        var succeeded: Bool
    }

    enum StoreError: Error { case inaccessible(String) }

    let directory: URL
    /// Told after each change is tried, on the store's queue.
    var onOutcome: (@Sendable (Outcome) -> Void)?
    /// Days this store has written, so the file there is known to be its own
    /// and needs no check before the next write. Queue only.
    private var writtenDays: Set<String> = []
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

    /// As `load(day:)`, telling a missing file from one that can't be read.
    func loadFile(day: String) -> DayFile {
        queue.sync { Self.readFile(url(for: day)) }
    }

    /// The days that have files, oldest first.
    func load(days: [String]) async -> [ActivityDayLog] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: days.sorted().compactMap { Self.read(url(for: $0)) })
            }
        }
    }

    /// As `load(days:)`, for a reader that may be superseded: once the
    /// calling task is cancelled it stops between files and returns nil, so
    /// a stale read doesn't hold up the next one behind it. Nil is never
    /// "no days"; only a reader that drops cancelled results should use this.
    func loadUnlessCancelled(days: [String]) async -> [ActivityDayLog]? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[ActivityDayLog]?, Never>) in
                queue.async { [self] in
                    var logs: [ActivityDayLog] = []
                    for day in days.sorted() {
                        if cancelled.withLock({ $0 }) { return continuation.resume(returning: nil) }
                        if let log = Self.read(url(for: day)) { logs.append(log) }
                    }
                    continuation.resume(returning: logs)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
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

    private static func read(_ url: URL) -> ActivityDayLog? { readFile(url).log }

    static func readFile(_ url: URL) -> DayFile {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return .absent }
        catch {
            logger.error("Could not open a day of activity: \(error.localizedDescription, privacy: .public)")
            return .inaccessible
        }
        do { return .loaded(try JSONDecoder().decode(ActivityDayLog.self, from: data).sanitized) }
        catch {
            logger.error("Could not read a day of activity: \(error.localizedDescription, privacy: .public)")
            return .corrupt
        }
    }

    private static let logger = Logger(subsystem: "local.sam.nidus", category: "activity")

    private func apply(_ change: Change) {
        var day: String?
        do {
            switch change {
            case .write(let log):
                day = log.day
                try write(log)
            case .clear:
                writtenDays.removeAll()
                for key in dayKeys() { try delete(key) }
            case .removeTitles:
                try rewrite { $0.hasTitles ? $0.removeTitles() : () }
            case .prune(let before):
                for key in dayKeys() where key < before { try delete(key) }
            }
            onOutcome?(Outcome(day: day, succeeded: true))
        } catch {
            Self.logger.error("Could not save activity: \(error.localizedDescription, privacy: .public)")
            onOutcome?(Outcome(day: day, succeeded: false))
        }
    }

    /// The first write of a day this run looks at what is there: a file that
    /// can't be read is left alone, and one that can't be decoded is kept
    /// beside the new one rather than lost.
    private func write(_ log: ActivityDayLog) throws {
        if !writtenDays.contains(log.day) {
            let file = url(for: log.day)
            switch Self.readFile(file) {
            case .inaccessible: throw StoreError.inaccessible(log.day)
            case .corrupt: try setAside(file)
            case .absent, .loaded: break
            }
        }
        try save(log)
        writtenDays.insert(log.day)
    }

    /// Renames an unreadable day to `<day>.json.corrupt-<time>` beside it.
    /// That name is not a day file, so nothing reads or prunes it.
    private func setAside(_ file: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        var aside = file.appendingPathExtension("corrupt-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: aside.path) {
            aside = file.appendingPathExtension("corrupt-\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: file, to: aside)
        Self.logger.error("Set aside an unreadable day of activity as \(aside.lastPathComponent, privacy: .public)")
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
        writtenDays.insert(log.day)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func delete(_ key: String) throws {
        writtenDays.remove(key)
        do { try FileManager.default.removeItem(at: url(for: key)) }
        catch CocoaError.fileNoSuchFile { }
    }
}
