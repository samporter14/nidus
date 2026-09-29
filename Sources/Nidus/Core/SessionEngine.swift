//
//  SessionEngine.swift
//  Nidus
//
//  The session state machine: idle, running or paused. It keeps an absolute
//  deadline rather than counting ticks, so a late tick, a sleep or a Nidus
//  relaunch never drifts the countdown. It owns no timer: whoever drives it
//  calls tick() (the browser sweep already runs once a second), and the tests
//  drive it with a fake clock.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

/// What a session blocks and for how long. The last one is kept, so the
/// shortcut can start it again.
struct SessionPlan: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Only the listed apps and websites are blocked.
        case block
        /// Everything except the listed apps and websites is blocked.
        case allow
    }

    var goal: String
    /// nil for an open-ended session, which still stops at `maximumDuration`.
    var duration: TimeInterval?
    var mode: Mode
    /// Bundle identifiers.
    var apps: [String]
    /// Domains; each also covers its subdomains.
    var websites: [String]
    /// Whether the apps a session quit are opened again when it ends.
    var reopensQuitApps: Bool = false
    /// Bundle identifiers opened when the session starts. They are never
    /// blocked by it, in either mode: a session does not quit what it opened.
    var launchApps: [String] = []
    /// Shortcuts run when the session starts and ends, by name: the way to
    /// turn an Apple Focus on and off, which macOS offers only to Shortcuts.
    var startShortcut: String?
    var endShortcut: String?
    /// No snooze and no pause, and ending early takes a deliberate step in
    /// the widget. Fixed when the session starts, so turning the setting off
    /// mid-session changes nothing.
    var strict: Bool = false

    static let maximumDuration: TimeInterval = 24 * 60 * 60

    var cappedDuration: TimeInterval {
        min(duration ?? Self.maximumDuration, Self.maximumDuration)
    }
}

/// A session in progress. Everything in it is persisted, so a Nidus
/// relaunch picks the session up where it was.
struct SessionState: Codable, Equatable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case running(deadline: Date)
        /// `bySleep` pauses end on wake; a pause the user chose does not.
        case paused(remaining: TimeInterval, bySleep: Bool)
    }

    var plan: SessionPlan
    var startedAt: Date
    var phase: Phase
    /// The planned duration plus every extension: elapsed is this minus
    /// what remains.
    var budget: TimeInterval
    /// Item (bundle identifier or domain) to the moment its snooze ends.
    var snoozes: [String: Date] = [:]
    /// Bundle identifiers this session quit, oldest first.
    var quitApps: [String] = []
    /// How often each app (bundle identifier) or site (domain) was blocked.
    var blocks: [String: Int] = [:]
    /// How often each app was quit.
    var quitCounts: [String: Int] = [:]
    /// Seconds each app spent frontmost while the session ran.
    var foreground: [String: TimeInterval] = [:]
    /// Display names for the keys above.
    var names: [String: String] = [:]
    /// Focused time as of the last checkpoint: all that is known of a session
    /// whose deadline passed while Nidus was not running.
    var seenElapsed: TimeInterval = 0
    /// Set when the session ends.
    var endedAt: Date?
    var focusedTime: TimeInterval?
}

/// A break after a completed session. Nothing is blocked; when it ends, the
/// plan it carries starts again.
struct BreakState: Codable, Equatable, Sendable {
    var plan: SessionPlan
    var endsAt: Date
    var length: TimeInterval
}

/// What is blocked at this moment, after snoozes. nil while idle, on a
/// break, or paused by the user. A pause for being away (asleep, or the
/// screen locked) freezes only the countdown and keeps blocking: undoing it
/// would put blocked tabs back on their pages behind the lock screen, then
/// block them again, with a card and a count, the moment the user is back.
struct Enforcement: Equatable, Sendable {
    var mode: SessionPlan.Mode
    /// Blocked apps in `.block` mode, allowed apps in `.allow` mode.
    var apps: Set<String>
    /// Blocked domains in `.block` mode, allowed domains in `.allow` mode.
    var websites: Set<String>
}

enum SessionEndReason: String, Codable, Sendable {
    /// The countdown reached zero.
    case completed
    /// The user ended it.
    case endedEarly
    /// The deadline passed while Nidus was not running.
    case expiredWhileAway
}

enum SessionEvent: Equatable, Sendable {
    case started
    case paused
    case resumed
    case extended
    case snoozed(String)
    case snoozeEnded(String)
    /// Carries the final state, so the owner can undo what the session did.
    /// The engine's `breakState` is set by then when a break follows.
    case ended(SessionEndReason, SessionState)
    /// A break is over without a session starting: stopped, or too late.
    case breakEnded
}

/// What the engine persists: the session or the break, if any, and the
/// last plan.
struct SessionRecord: Codable, Equatable, Sendable {
    var session: SessionState?
    var lastPlan: SessionPlan?
    var pendingBreak: BreakState?
}

@MainActor
protocol SessionStore: AnyObject {
    func load() -> SessionRecord?
    func save(_ record: SessionRecord)
}

/// A JSON file, written atomically, in ~/Library/Application Support/Nidus.
@MainActor
final class FileSessionStore: SessionStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    func save(_ record: SessionRecord) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}

@MainActor
final class SessionEngine {
    static let defaultSnooze: TimeInterval = 3 * 60

    private(set) var session: SessionState?
    private(set) var lastPlan: SessionPlan?
    /// Set between sessions while a break runs.
    private(set) var breakState: BreakState?
    /// The break after a completed, timed session; 0 for none.
    var breakLength: TimeInterval = 0
    /// A break that ran out more than this long ago, while the Mac slept or
    /// Nidus was not running, is dropped rather than starting a session
    /// nobody may be there for.
    static let breakGrace: TimeInterval = 60
    /// Called after every change, with the change.
    var onEvent: (SessionEvent) -> Void = { _ in }

    private let store: SessionStore?
    private let now: () -> Date

    init(store: SessionStore?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    // MARK: Reading

    var isRunning: Bool {
        if case .running = session?.phase { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = session?.phase { return true }
        return false
    }

    var isOnBreak: Bool { breakState != nil }

    /// Time left of the break. nil when there is none.
    var breakRemaining: TimeInterval? {
        breakState.map { max(0, $0.endsAt.timeIntervalSince(now())) }
    }

    /// When the break ends, if that is within `lead` seconds from now.
    func breakEnding(within lead: TimeInterval) -> Date? {
        guard let breakState, breakState.endsAt > now(), breakState.endsAt <= now().addingTimeInterval(lead) else { return nil }
        return breakState.endsAt
    }

    /// Time left, frozen while paused. nil when idle.
    var remaining: TimeInterval? {
        guard let session else { return nil }
        switch session.phase {
        case .running(let deadline): return max(0, deadline.timeIntervalSince(now()))
        case .paused(let remaining, _): return remaining
        }
    }

    /// Time spent focused, pauses excluded; what an open-ended session shows.
    var elapsed: TimeInterval? {
        guard let session, let remaining else { return nil }
        return max(0, session.budget - remaining)
    }

    var enforcement: Enforcement? {
        guard let session else { return nil }
        if case .paused(_, bySleep: false) = session.phase { return nil }
        let snoozed = Set(session.snoozes.keys)
        let launched = Set(session.plan.launchApps)
        let apps = Set(session.plan.apps)
        let websites = Set(session.plan.websites)
        switch session.plan.mode {
        case .block:
            return Enforcement(mode: .block, apps: apps.subtracting(snoozed).subtracting(launched),
                               websites: websites.subtracting(snoozed))
        case .allow:
            return Enforcement(mode: .allow, apps: apps.union(snoozed).union(launched), websites: websites.union(snoozed))
        }
    }

    // MARK: Lifecycle

    /// Loads the saved record. A session whose deadline passed while Nidus was
    /// not running ends now, with `.expiredWhileAway`, so the owner still
    /// restores what it changed.
    func restore() {
        guard let record = store?.load() else { return }
        lastPlan = record.lastPlan
        session = record.session
        // A break that ran out while Nidus was away: see `tick()`.
        breakState = record.pendingBreak
        guard var session else { return }
        switch session.phase {
        case .running(let deadline) where deadline <= now():
            finish(.expiredWhileAway)
        case .paused(let remaining, bySleep: true):
            // The wake that would have resumed it was missed.
            session.phase = .running(deadline: now().addingTimeInterval(remaining))
            self.session = session
            save()
        default:
            break
        }
    }

    func start(_ plan: SessionPlan) {
        if session != nil { finish(.endedEarly) }
        breakState = nil
        let start = now()
        session = SessionState(plan: plan, startedAt: start,
                               phase: .running(deadline: start.addingTimeInterval(plan.cappedDuration)),
                               budget: plan.cappedDuration)
        lastPlan = plan
        commit(.started)
    }

    /// Not in a strict session: pausing stops the blocking.
    func pause() {
        guard session?.plan.strict != true else { return }
        pause(bySleep: false)
    }

    func resume() {
        guard var session, case .paused(let remaining, _) = session.phase else { return }
        session.phase = .running(deadline: now().addingTimeInterval(remaining))
        self.session = session
        commit(.resumed)
    }

    func end() {
        guard session != nil else { return }
        finish(.endedEarly)
    }

    /// Adds time to a running or paused session, up to `maximumDuration` left.
    func extend(by seconds: TimeInterval) {
        guard var session, let before = remaining, seconds > 0 else { return }
        let after = min(before + seconds, SessionPlan.maximumDuration)
        guard after > before else { return }
        switch session.phase {
        case .running:
            session.phase = .running(deadline: now().addingTimeInterval(after))
        case .paused(_, let bySleep):
            session.phase = .paused(remaining: after, bySleep: bySleep)
        }
        session.budget += after - before
        self.session = session
        commit(.extended)
    }

    /// Lets one app or website through for a while. Only while running, and
    /// never in a strict session.
    func snooze(_ item: String, for seconds: TimeInterval = defaultSnooze) {
        guard var session, case .running = session.phase, seconds > 0, !session.plan.strict else { return }
        session.snoozes[item] = now().addingTimeInterval(seconds)
        self.session = session
        commit(.snoozed(item))
    }

    /// Ends a snooze early: the item is blocked again at once.
    func endSnooze(_ item: String) {
        guard var session, session.snoozes[item] != nil else { return }
        session.snoozes[item] = nil
        self.session = session
        commit(.snoozeEnded(item))
    }

    /// Snoozes that run out within `lead` seconds, soonest first.
    func snoozesEnding(within lead: TimeInterval) -> [(item: String, end: Date)] {
        guard let session else { return [] }
        let now = now(), limit = now.addingTimeInterval(lead)
        return session.snoozes
            .filter { $0.value > now && $0.value <= limit }
            .map { (item: $0.key, end: $0.value) }
            .sorted { $0.end != $1.end ? $0.end < $1.end : $0.item < $1.item }
    }

    /// Notes an app the session quit, for `reopensQuitApps` and the stats.
    func recordQuit(_ bundleID: String, name: String? = nil) {
        guard var session else { return }
        if !session.quitApps.contains(bundleID) { session.quitApps.append(bundleID) }
        session.quitCounts[bundleID, default: 0] += 1
        if let name { session.names[bundleID] = name }
        self.session = session
        save()
    }

    /// Counts one block of an app (bundle identifier) or site (domain).
    func recordBlock(_ key: String, name: String) {
        guard var session else { return }
        session.blocks[key, default: 0] += 1
        session.names[key] = name
        self.session = session
        save()
    }

    /// Adds time to the app that was frontmost. Kept in memory; the next
    /// checkpoint or event saves it, so a once-a-second caller does not
    /// write the file once a second.
    func recordForeground(_ bundleID: String, name: String, seconds: TimeInterval) {
        guard var session, case .running = session.phase, seconds > 0 else { return }
        session.foreground[bundleID, default: 0] += seconds
        session.names[bundleID] = name
        self.session = session
    }

    /// Saves the session with its focused time so far.
    func checkpoint() {
        guard var session, let elapsed else { return }
        session.seenElapsed = elapsed
        self.session = session
        save()
    }

    // MARK: Breaks

    /// Starts a break now, with the plan to start again when it ends.
    func startBreak(plan: SessionPlan, length: TimeInterval) {
        guard session == nil, length > 0 else { return }
        breakState = BreakState(plan: plan, endsAt: now().addingTimeInterval(length), length: length)
        save()
    }

    /// Starts the next session now instead of waiting.
    func skipBreak() {
        guard let breakState else { return }
        start(breakState.plan)
    }

    /// Stops here: the break ends and no session follows.
    func endBreak() {
        guard breakState != nil else { return }
        breakState = nil
        commit(.breakEnded)
    }

    /// Ends the session at its deadline, expires snoozes, and ends a break
    /// that is over. Call often; it is cheap when nothing is due.
    func tick() {
        if let pending = breakState {
            guard pending.endsAt <= now() else { return }
            if now().timeIntervalSince(pending.endsAt) <= Self.breakGrace {
                start(pending.plan)
            } else {
                endBreak()
            }
            return
        }
        guard let session else { return }
        if case .running(let deadline) = session.phase, deadline <= now() {
            finish(.completed)
            return
        }
        let due = session.snoozes.filter { $0.value <= now() }.keys.sorted()
        guard !due.isEmpty else { return }
        var updated = session
        due.forEach { updated.snoozes[$0] = nil }
        self.session = updated
        save()
        due.forEach { onEvent(.snoozeEnded($0)) }
    }

    // MARK: Sleep

    /// A sleeping Mac is not focusing: the countdown stops until wake.
    func systemWillSleep() {
        pause(bySleep: true)
    }

    func systemDidWake() {
        guard case .paused(_, bySleep: true) = session?.phase else { return }
        resume()
    }

    // MARK: Private

    private func pause(bySleep: Bool) {
        guard var session, case .running(let deadline) = session.phase else { return }
        session.phase = .paused(remaining: max(0, deadline.timeIntervalSince(now())), bySleep: bySleep)
        self.session = session
        commit(.paused)
    }

    private func finish(_ reason: SessionEndReason) {
        guard var ended = session else { return }
        ended.endedAt = now()
        ended.focusedTime = reason == .expiredWhileAway ? ended.seenElapsed : (elapsed ?? 0)
        session = nil
        // A completed, timed session earns the break; one ended early, or
        // open-ended, does not.
        if reason == .completed, breakLength > 0, ended.plan.duration != nil {
            breakState = BreakState(plan: ended.plan, endsAt: now().addingTimeInterval(breakLength), length: breakLength)
        }
        commit(.ended(reason, ended))
    }

    private func commit(_ event: SessionEvent) {
        save()
        onEvent(event)
    }

    private func save() {
        store?.save(SessionRecord(session: session, lastPlan: lastPlan, pendingBreak: breakState))
    }
}

// MARK: - Decoding older files

// Every field added after 1.0 is optional in the file, so a session or last
// plan saved by an earlier version still loads after an update instead of
// being dropped.

extension SessionPlan {
    enum CodingKeys: String, CodingKey {
        case goal, duration, mode, apps, websites, reopensQuitApps, launchApps, startShortcut, endShortcut, strict
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            goal: try c.decodeIfPresent(String.self, forKey: .goal) ?? "",
            duration: try c.decodeIfPresent(TimeInterval.self, forKey: .duration),
            mode: try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .block,
            apps: try c.decodeIfPresent([String].self, forKey: .apps) ?? [],
            websites: try c.decodeIfPresent([String].self, forKey: .websites) ?? [],
            reopensQuitApps: try c.decodeIfPresent(Bool.self, forKey: .reopensQuitApps) ?? false,
            launchApps: try c.decodeIfPresent([String].self, forKey: .launchApps) ?? [],
            startShortcut: try c.decodeIfPresent(String.self, forKey: .startShortcut),
            endShortcut: try c.decodeIfPresent(String.self, forKey: .endShortcut),
            strict: try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false
        )
    }
}

extension SessionState {
    enum CodingKeys: String, CodingKey {
        case plan, startedAt, phase, budget, snoozes, quitApps, blocks, quitCounts, foreground, names
        case seenElapsed, endedAt, focusedTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(SessionPlan.self, forKey: .plan)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        phase = try c.decode(Phase.self, forKey: .phase)
        budget = try c.decode(TimeInterval.self, forKey: .budget)
        snoozes = try c.decodeIfPresent([String: Date].self, forKey: .snoozes) ?? [:]
        quitApps = try c.decodeIfPresent([String].self, forKey: .quitApps) ?? []
        blocks = try c.decodeIfPresent([String: Int].self, forKey: .blocks) ?? [:]
        quitCounts = try c.decodeIfPresent([String: Int].self, forKey: .quitCounts) ?? [:]
        foreground = try c.decodeIfPresent([String: TimeInterval].self, forKey: .foreground) ?? [:]
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        seenElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .seenElapsed) ?? 0
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        focusedTime = try c.decodeIfPresent(TimeInterval.self, forKey: .focusedTime)
    }
}
