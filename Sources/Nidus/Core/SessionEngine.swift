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
//  Shared by the app and its tests.
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

    // Added in 0.4. A plan is the snapshot of a running session: everything
    // below is resolved when it starts (setup over Settings), so editing a
    // setup, a project or Settings mid-session changes nothing it committed to.

    /// The saved setup it came from.
    var setupID: UUID?
    /// The project it counts toward, and that project's name when it started,
    /// so history still says which project after a rename or a delete.
    var projectID: UUID?
    var projectName: String?
    /// The break after it, frozen at start. 0: none. nil exists only on
    /// legacy plans and falls back to `SessionEngine.breakLength`.
    var breakLength: TimeInterval?
    /// What stays blocked during that break. nil or empty: nothing.
    var breakRules: BreakRules?
    /// Pages let through inside the block list. Block mode only.
    var websiteExceptions: [WebsiteException] = []
    /// Documents, folders and pages opened when it starts.
    var resources: [WorkspaceResource] = []
    /// Set on a plan the engine starts again by itself when a break ends: its
    /// apps and Shortcuts run again, its documents and pages are not opened a
    /// second time.
    var isContinuation: Bool = false
    /// Its place in a sequence, when it is a sequence's work block.
    var sequenceStep: SequenceStepRef?

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
    /// Opt-in activity detail. nil means an older or untracked session.
    var activity: [FocusActivity]?
    /// Ordered local observations. nil means an older or untracked session.
    var activitySegments: [FocusActivitySegment]?
    var activityTimelineTruncated: Bool? = nil
    /// Separates observations across pauses and process relaunches.
    var activityContinuity: Int = 0
    /// The first moment a new running span may claim as observed.
    var activityContinuityStartedAt: Date?
    /// Display names for the keys above.
    var names: [String: String] = [:]
    /// Focused time as of the last checkpoint: all that is known of a session
    /// whose deadline passed while Nidus was not running.
    var seenElapsed: TimeInterval = 0
    /// Set when the session ends.
    var endedAt: Date?
    var focusedTime: TimeInterval?
    /// When the user paused it (not sleep or a locked screen, which are not
    /// forgotten), for the "Still paused" reminder. nil while running.
    var pausedAt: Date?
    /// The reminder was given for this pause: once per pause.
    var pauseReminded = false
}

/// A break after a completed session. Nothing is blocked unless it has
/// rules; when it ends, the plan it carries starts.
struct BreakState: Codable, Equatable, Sendable {
    var plan: SessionPlan
    var endsAt: Date
    var length: TimeInterval
    /// What stays blocked until it ends. nil or empty: nothing (0.3's break).
    var rules: BreakRules?

    init(plan: SessionPlan, endsAt: Date, length: TimeInterval, rules: BreakRules? = nil) {
        self.plan = plan
        self.endsAt = endsAt
        self.length = length
        self.rules = rules
    }
}

/// What is blocked at this moment, after snoozes. nil while idle, on an
/// unrestricted break, or paused by the user. A break with rules blocks its
/// own apps and websites, in block mode, and nothing else. A pause for being away (asleep, or the
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
    /// Ending early was taken back (`undoEnd`): the same session is running
    /// again. Not a start: nothing is opened, launched or run as at a start.
    case undone
    /// The user paused it and it has stayed paused for `pauseReminderDelay`.
    case pauseLingering
}

/// A session the user just ended early, kept for a few seconds so ending it
/// can be taken back. Held in memory only: a relaunch inside the window
/// loses it, which only means no Undo.
struct UndoableEnd: Equatable, Sendable {
    /// The session as it stood when it ended (`endedAt` and `focusedTime` set).
    var state: SessionState
    var endedAt: Date
}

/// What the engine persists: the session or the break, if any, and the
/// last plan.
struct SessionRecord: Codable, Equatable, Sendable {
    var session: SessionState?
    var lastPlan: SessionPlan?
    var pendingBreak: BreakState?
    /// The sequence the session or break belongs to. 0.4.
    var sequence: SequenceRun?

    init(session: SessionState? = nil, lastPlan: SessionPlan? = nil, pendingBreak: BreakState? = nil,
         sequence: SequenceRun? = nil) {
        self.session = session
        self.lastPlan = lastPlan
        self.pendingBreak = pendingBreak
        self.sequence = sequence
    }
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
    /// The sequence the session or break belongs to, saved and restored with
    /// them. Its steps are a snapshot taken when it started.
    private(set) var sequence: SequenceRun?
    /// The break after a completed, timed session; 0 for none.
    var breakLength: TimeInterval = 0
    /// A break that ran out more than this long ago, while the Mac slept or
    /// Nidus was not running, is dropped rather than starting a session
    /// nobody may be there for.
    static let breakGrace: TimeInterval = 60
    /// How long after ending early the session can be brought back.
    static let undoWindow: TimeInterval = 5
    /// How long a pause the user chose may last before one gentle reminder.
    static let pauseReminderDelay: TimeInterval = 10 * 60
    /// The last end that can still be undone; see `canUndoEnd`.
    private(set) var undoableEnd: UndoableEnd?
    /// Whether the user is away (the screen is locked): a reminder waits for
    /// them rather than showing behind the lock screen. Set by the controller.
    var isAway: () -> Bool = { false }
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

    /// Ending early can be taken back: the end was the user's, early, of a
    /// non-strict session that was not part of a sequence, within
    /// `undoWindow`, and nothing else has started since (no session, no break).
    var canUndoEnd: Bool {
        guard let undoableEnd, session == nil, breakState == nil else { return false }
        let age = now().timeIntervalSince(undoableEnd.endedAt)
        guard age >= 0, age <= Self.undoWindow, !undoableEnd.state.plan.strict else { return false }
        // A deadline that has passed since would only end it again at once.
        if case .running(let deadline) = undoableEnd.state.phase, deadline <= now() { return false }
        return true
    }

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
        guard let session else { return breakEnforcement }
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

    /// What a break with rules keeps blocked: its own apps and websites, in
    /// block mode (a break never narrows to an allow list). The work session's
    /// rules are released while it runs. nil for an unrestricted break, and
    /// when no break is on.
    var breakEnforcement: Enforcement? {
        guard session == nil, let rules = breakState?.rules, !rules.isUnrestricted else { return nil }
        return Enforcement(mode: .block, apps: Set(rules.apps), websites: Set(rules.websites))
    }

    /// Whether a sequence is under way: a block running (or paused), or the
    /// break between two blocks. A run left over from something else (it is
    /// saved apart from the block it belongs to) is not one.
    var isInSequence: Bool {
        guard let id = sequence?.id else { return false }
        if let session { return session.plan.sequenceStep?.runID == id }
        return breakState?.plan.sequenceStep?.runID == id
    }

    // MARK: Lifecycle

    /// Loads the saved record. A session whose deadline passed while Nidus was
    /// not running ends now, with `.expiredWhileAway`, so the owner still
    /// restores what it changed.
    func restore(allowActivity: Bool = true, allowTitles: Bool = true, excludedApps: Set<String> = []) {
        guard let record = store?.load() else { return }
        undoableEnd = nil
        lastPlan = record.lastPlan
        session = record.session
        // The interval while Nidus was closed was not observed, even when
        // two recorded dates might happen to touch at the clock's precision.
        if session?.activitySegments != nil {
            session?.activityContinuity += 1
            session?.activityContinuityStartedAt = now()
        }
        // A break that ran out while Nidus was away: see `tick()`.
        breakState = record.pendingBreak
        sequence = record.sequence
        // A run belongs to the block or break it is saved with. One that
        // doesn't match (the sequence field was written wrongly, or the plan
        // was) is let go, and the session carries on as an ordinary one.
        if let run = sequence {
            // A step the run doesn't have (a file edited by hand) is no run.
            if !run.steps.indices.contains(run.index) { sequence = nil }
            if let session, session.plan.sequenceStep?.runID != run.id { sequence = nil }
            if session == nil, let pending = breakState, pending.plan.sequenceStep?.runID != run.id { sequence = nil }
        }
        // Apply current privacy choices before an overdue session can finish
        // and enter history. Settings are loaded before the controller starts.
        if !allowActivity {
            clearCurrentActivity()
        } else {
            if !allowTitles { removeCurrentActivityTitles() }
            excludeCurrentActivity(appIDs: excludedApps)
        }
        guard var session else { return }
        // A pause saved by a version without the reminder: count from now.
        if case .paused(_, bySleep: false) = session.phase, session.pausedAt == nil {
            session.pausedAt = now()
            self.session = session
        }
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

    /// Starts a session of its own, ending a running one and any break or
    /// sequence first. A plan that was a sequence's block, or a break's
    /// continuation, starts as a plain new session: it is not part of that
    /// run any more, and its documents and pages are new again.
    func start(_ plan: SessionPlan) {
        if session != nil { finish(.endedEarly) }
        breakState = nil
        sequence = nil
        var plan = plan
        plan.sequenceStep = nil
        plan.isContinuation = false
        begin(plan)
    }

    /// Starts a plan now. Does not touch the sequence, which the caller has
    /// already set or cleared.
    private func begin(_ plan: SessionPlan) {
        makeSession(plan)
        commit(.started)
    }

    /// The one place a session is made, with no event.
    private func makeSession(_ plan: SessionPlan) {
        breakState = nil
        undoableEnd = nil
        let start = now()
        session = SessionState(plan: plan, startedAt: start,
                               phase: .running(deadline: start.addingTimeInterval(plan.cappedDuration)),
                               budget: plan.cappedDuration)
        lastPlan = plan
    }

    /// Not in a strict session: pausing stops the blocking.
    func pause() {
        guard session?.plan.strict != true else { return }
        pause(bySleep: false)
    }

    func resume() {
        guard var session, case .paused(let remaining, _) = session.phase else { return }
        session.phase = .running(deadline: now().addingTimeInterval(remaining))
        session.activityContinuityStartedAt = now()
        session.pausedAt = nil
        session.pauseReminded = false
        self.session = session
        commit(.resumed)
    }

    /// Ends the session early. A non-strict one that was not part of a
    /// sequence can be brought back with `undoEnd` for `undoWindow` seconds.
    func end() {
        guard session != nil else { return }
        finish(.endedEarly, undoable: true)
    }

    /// Takes back ending early: the same session runs again, with its plan,
    /// deadline, snoozes and counts as they were. Its deadline is the
    /// original absolute one, so the seconds spent ended count as focus
    /// (a session paused when it ended comes back paused, with the same
    /// time left). Refuses, changing nothing, when `canUndoEnd` is false.
    /// History and the app side are the owner's: see `.undone`.
    @discardableResult
    func undoEnd() -> Bool {
        guard canUndoEnd, var restored = undoableEnd?.state else { return false }
        restored.endedAt = nil
        restored.focusedTime = nil
        // The seconds ended were not observed.
        if restored.activitySegments != nil {
            restored.activityContinuity += 1
            restored.activityContinuityStartedAt = now()
        }
        session = restored
        undoableEnd = nil
        commit(.undone)
        return true
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

    /// Blocks these apps too, for the rest of this session only: a browser
    /// whose tabs Nidus can't reach, blocked whole instead. In an allow list
    /// that means taking them off it. Settings and the setup are untouched.
    func blockAppsForSession(_ bundleIDs: [String]) {
        guard var session, !bundleIDs.isEmpty else { return }
        switch session.plan.mode {
        case .block:
            for id in bundleIDs where !session.plan.apps.contains(id) { session.plan.apps.append(id) }
        case .allow:
            session.plan.apps.removeAll { bundleIDs.contains($0) }
        }
        session.plan.launchApps.removeAll { bundleIDs.contains($0) }
        guard session != self.session else { return }
        self.session = session
        commit(.extended)
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
        guard var session, case .running = session.phase, seconds.isFinite, seconds > 0,
              let elapsed else { return }
        let credited = session.foreground.values.reduce(0, +)
        let amount = min(seconds, max(0, elapsed - credited))
        guard amount > 0 else { return }
        session.foreground[bundleID, default: 0] += amount
        session.names[bundleID] = name
        self.session = session
    }

    /// Makes a tracked session distinguishable from legacy history even if
    /// no app qualifies for a row. Called only after the user enables tracking.
    func initializeActivity() {
        guard var session else { return }
        if session.activity == nil { session.activity = [] }
        if session.activitySegments == nil { session.activitySegments = [] }
        self.session = session
    }

    /// A tracked tick that could not identify a qualifying frontmost app
    /// separates the observations on either side of it.
    func breakActivityContinuity(at sampledAt: Date? = nil) {
        guard var session, case .running = session.phase, session.activitySegments != nil else { return }
        session.activityContinuity += 1
        session.activityContinuityStartedAt = sampledAt ?? now()
        self.session = session
    }

    /// Credits a single observed interval, never more than the focused time
    /// available at this instant. This also updates the historical app totals
    /// once, so detail and aggregate cannot double-count a tick.
    func recordActivity(appID: String, appName: String, site: String? = nil,
                        title: String? = nil, seconds: TimeInterval, sampledAt: Date? = nil) {
        guard var session, case .running(let deadline) = session.phase,
              seconds.isFinite, seconds > 0, !appID.isEmpty,
              let elapsed else { return }
        var rows = session.activity ?? []
        let credited = session.foreground.values.reduce(0, +)
        let amount = min(seconds, max(0, elapsed - credited))
        guard amount > 0 else { return }
        // Bound the number and length of distinct names retained per session.
        let safeTitle = title.flatMap(ActivityProbe.cleanTitle)
        let rowTitle = rows.count < 120 ? safeTitle : nil
        let rowSite = rows.count < 200 ? ActivityTimeline.safeSite(site) : nil
        if let index = rows.firstIndex(where: { $0.appID == appID && $0.site == rowSite && $0.title == rowTitle }) {
            rows[index].seconds += amount
            rows[index].appName = appName
        } else if rows.count < 240 {
            rows.append(FocusActivity(appID: appID, appName: appName, site: rowSite,
                                      title: rowTitle, seconds: amount))
        } else if let index = rows.firstIndex(where: { $0.appID == appID && $0.site == nil && $0.title == nil }) {
            rows[index].seconds += amount
        } else {
            // Keep detailed seconds reconciled with app totals at the cap.
            // Collapse the smallest row for this app, or use an honest
            // cross-app overflow row when this is a new app.
            if let index = rows.indices.filter({ rows[$0].appID == appID })
                .min(by: { rows[$0].seconds < rows[$1].seconds }) {
                rows[index].site = nil
                rows[index].title = nil
                rows[index].seconds += amount
            } else if let index = rows.firstIndex(where: { $0.appID == "com.nidus.activity.other" }) {
                rows[index].seconds += amount
            } else if let index = rows.indices.min(by: { rows[$0].seconds < rows[$1].seconds }) {
                let rolled = rows[index].seconds + amount
                rows[index] = FocusActivity(id: rows[index].id, appID: "com.nidus.activity.other",
                                            appName: "Other apps", seconds: rolled)
            }
        }
        session.activity = rows
        // This path is called for brief, sampled foreground intervals. A
        // stalled timer cannot prove that the same context stayed in front.
        if seconds <= 5 {
            var segments = session.activitySegments ?? []
            let observationEnd = sampledAt ?? now()
            let end = min(observationEnd, deadline)
            var start = max(observationEnd.addingTimeInterval(-seconds),
                            end.addingTimeInterval(-amount),
                            session.activityContinuityStartedAt ?? session.startedAt)
            if let last = segments.last {
                start = max(start, last.end)
            }
            if start < end {
                let next = FocusActivitySegment(start: start, end: end, appID: appID,
                                                appName: appName, site: rowSite, title: rowTitle,
                                                continuity: session.activityContinuity)
                if let last = segments.last, ActivityTimeline.touches(last, next),
                   ActivityTimeline.sameContext(last, next) {
                    segments[segments.count - 1].end = end
                } else {
                    segments.append(next)
                    if segments.count > ActivityTimeline.limit {
                        segments.removeFirst(segments.count - ActivityTimeline.limit)
                        session.activityTimelineTruncated = true
                    }
                }
                session.activitySegments = segments
            }
        }
        session.foreground[appID, default: 0] += amount
        session.names[appID] = appName
        self.session = session
    }

    /// Clear the running session too when history is cleared or disabled.
    func clearCurrentActivity() {
        guard var session else { return }
        for appID in session.foreground.keys where session.blocks[appID] == nil && session.quitCounts[appID] == nil {
            session.names.removeValue(forKey: appID)
        }
        session.foreground = [:]
        session.activity = nil
        session.activitySegments = nil
        session.activityTimelineTruncated = nil
        self.session = session
        save()
    }

    /// An app excluded in Settings disappears from the running checkpoint,
    /// including the older app-total field used by existing Stats views.
    func excludeCurrentActivity(appIDs: Set<String>) {
        guard var session, !appIDs.isEmpty else { return }
        session.activity?.removeAll { appIDs.contains($0.appID) }
        if let segments = session.activitySegments {
            var kept: [FocusActivitySegment] = []
            var offset = 0
            var removedSinceLastKept = false
            var removedAny = false
            for var segment in segments {
                if appIDs.contains(segment.appID) {
                    removedSinceLastKept = true
                    removedAny = true
                    continue
                }
                // The removed interval might be shorter than the switch
                // threshold. Keep a boundary across that hidden interval.
                if removedSinceLastKept && !kept.isEmpty { offset += 1 }
                removedSinceLastKept = false
                segment.continuity += offset
                kept.append(segment)
            }
            session.activitySegments = kept
            if removedAny {
                session.activityContinuity = max(session.activityContinuity, kept.last?.continuity ?? 0) + 1
                session.activityContinuityStartedAt = now()
            }
        }
        for appID in appIDs {
            session.foreground.removeValue(forKey: appID)
            if session.blocks[appID] == nil && session.quitCounts[appID] == nil {
                session.names.removeValue(forKey: appID)
            }
        }
        self.session = session
        save()
    }

    /// Turning off names removes them from the active checkpoint as well as
    /// the controller's transient probe cache. Finished history is retained.
    func removeCurrentActivityTitles() {
        guard var session, session.activity != nil || session.activitySegments != nil else { return }
        if let activity = session.activity {
            session.activity = ActivityRedaction.withoutTitles(activity)
        }
        if let segments = session.activitySegments {
            let redacted = ActivityRedaction.withoutTitles(segments)
            session.activitySegments = redacted
            if segments.contains(where: { $0.title != nil }) {
                session.activityContinuity = max(session.activityContinuity, redacted.last?.continuity ?? 0) + 1
                session.activityContinuityStartedAt = now()
            }
        }
        self.session = session
        save()
    }

    /// Saves the session with its focused time so far.
    func checkpoint() {
        guard var session, let elapsed else { return }
        session.seenElapsed = elapsed
        self.session = session
        save()
    }

    // MARK: Breaks

    /// Starts a break now, with the plan to start again when it ends. The
    /// break keeps the plan's own rules blocked unless `rules` says otherwise.
    func startBreak(plan: SessionPlan, length: TimeInterval, rules: BreakRules? = nil) {
        guard session == nil, length > 0 else { return }
        undoableEnd = nil
        breakState = BreakState(plan: plan, endsAt: now().addingTimeInterval(length), length: length,
                                rules: rules ?? plan.breakRules)
        save()
    }

    /// Starts the next session now instead of waiting. In a sequence that is
    /// the next work block.
    func skipBreak() {
        guard let breakState else { return }
        startAfterBreak(breakState)
    }

    /// Stops here: the break ends and no session follows. In a sequence the
    /// run ends with it: there is no next block.
    func endBreak() {
        guard breakState != nil else { return }
        breakState = nil
        sequence = nil
        commit(.breakEnded)
    }

    /// The break is over: its plan starts. A sequence moves to that block; any
    /// other break restarts the plan it followed, as a continuation of it.
    private func startAfterBreak(_ pending: BreakState) {
        var plan = pending.plan
        if let run = sequence, let step = plan.sequenceStep, step.runID == run.id {
            // As `advanceSequence` set it: a block opens its documents and
            // pages unless the one before it opened the very same.
            sequence?.index = step.index
        } else {
            sequence = nil
            plan.sequenceStep = nil
            plan.isContinuation = true
        }
        begin(plan)
    }

    /// Ends the session at its deadline, expires snoozes, and ends a break
    /// that is over. Call often; it is cheap when nothing is due.
    func tick() {
        if let pending = breakState {
            guard pending.endsAt <= now() else { return }
            if now().timeIntervalSince(pending.endsAt) <= Self.breakGrace {
                startAfterBreak(pending)
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
        remindOfForgottenPause()
        guard let current = self.session else { return }
        let due = current.snoozes.filter { $0.value <= now() }.keys.sorted()
        guard !due.isEmpty else { return }
        var updated = current
        due.forEach { updated.snoozes[$0] = nil }
        self.session = updated
        save()
        due.forEach { onEvent(.snoozeEnded($0)) }
    }

    /// A pause the user chose that has lasted `pauseReminderDelay` gets one
    /// reminder (`.pauseLingering`), once per pause, never while the screen is
    /// locked (it waits for them to come back). Nothing resumes or ends it.
    private func remindOfForgottenPause() {
        guard var session, case .paused(_, bySleep: false) = session.phase, !session.plan.strict,
              !session.pauseReminded, let pausedAt = session.pausedAt,
              now().timeIntervalSince(pausedAt) >= Self.pauseReminderDelay, !isAway() else { return }
        session.pauseReminded = true
        self.session = session
        save()
        onEvent(.pauseLingering)
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
        session.pausedAt = bySleep ? nil : now()
        session.pauseReminded = false
        session.activityContinuity += 1
        self.session = session
        commit(.paused)
    }

    private func finish(_ reason: SessionEndReason, undoable: Bool = false) {
        guard var ended = session else { return }
        ended.endedAt = now()
        ended.focusedTime = reason == .expiredWhileAway ? ended.seenElapsed : (elapsed ?? 0)
        // Ending early can be taken back, except in a strict session (its end
        // gate is unchanged) and in a sequence (ending a block ends the run,
        // which is not put back).
        let inSequence = sequence != nil || ended.plan.sequenceStep != nil
        undoableEnd = undoable && reason == .endedEarly && !ended.plan.strict && !inSequence
            ? UndoableEnd(state: ended, endedAt: now()) : nil
        session = nil
        // The next block of a sequence that starts with no break between.
        var following: SessionPlan?
        if sequence != nil || ended.plan.sequenceStep != nil {
            following = advanceSequence(after: reason, from: ended.plan)
        } else if reason == .completed, ended.plan.duration != nil {
            // A completed, timed session earns the break; one ended early, or
            // open-ended, does not. The plan's own length, else Settings'.
            let length = ended.plan.breakLength ?? breakLength
            if length > 0 {
                breakState = BreakState(plan: ended.plan, endsAt: now().addingTimeInterval(length), length: length,
                                        rules: ended.plan.breakRules)
            }
        }
        if let following {
            // Begun before the end is announced, so what watches the engine
            // sees one change of rules (the last block's to the next's), not a
            // gap with nothing blocked in between.
            startBlock(following)
            save()
            onEvent(.ended(reason, ended))
            onEvent(.started)
        } else {
            commit(.ended(reason, ended))
        }
    }

    // MARK: Sequences

    /// Starts a resolved sequence: its first block now. Only the model's
    /// guarded start path calls this, after the same checks as `startSession`;
    /// it still refuses while a session or a break is on, so it can never end
    /// one. False when nothing started (the run has no work block first).
    @discardableResult
    func startSequence(_ run: SequenceRun) -> Bool {
        guard session == nil, breakState == nil, case .work(var plan)? = run.steps.first else { return false }
        var run = run
        run.index = 0
        plan.sequenceStep = run.ref(at: 0)
        plan.isContinuation = false
        sequence = run
        begin(plan)
        return true
    }

    /// Whether a sequence's next block would only open again what the block
    /// before it opened: the same setup's documents and pages, in a run of
    /// one setup. They are still open, so the block counts as a continuation
    /// and opens nothing (its apps and Shortcuts still run, as at any start).
    nonisolated static func opensWhatIsOpen(_ previous: SessionPlan, then next: SessionPlan) -> Bool {
        !next.resources.isEmpty && next.resources == previous.resources
    }

    /// Moves the run on after a block ended. Only a completed block goes on:
    /// ending one early, or finding its deadline passed while Nidus was away,
    /// ends the run. Returns a block to start straight away, or sets the break
    /// that comes first, or ends the run after its last block. The ordinary
    /// break (the plan's, or Settings') is never added in a run.
    private func advanceSequence(after reason: SessionEndReason, from previous: SessionPlan) -> SessionPlan? {
        guard reason == .completed, var run = sequence, let next = run.nextBlock() else {
            sequence = nil
            return nil
        }
        var plan = next.plan
        plan.sequenceStep = run.ref(at: next.index)
        plan.isContinuation = Self.opensWhatIsOpen(previous, then: plan)
        if let rest = next.rest {
            run.index = rest.index
            sequence = run
            breakState = BreakState(plan: plan, endsAt: now().addingTimeInterval(rest.length), length: rest.length,
                                    rules: rest.rules)
            return nil
        }
        sequence = run
        return plan
    }

    /// Makes the session of a block the run has moved to, with no event.
    private func startBlock(_ plan: SessionPlan) {
        if let step = plan.sequenceStep { sequence?.index = step.index }
        makeSession(plan)
    }

    private func commit(_ event: SessionEvent) {
        save()
        onEvent(event)
    }

    private func save() {
        store?.save(SessionRecord(session: session, lastPlan: lastPlan, pendingBreak: breakState, sequence: sequence))
    }
}

// MARK: - Decoding older files

// Every field added after 1.0 is optional in the file, so a session or last
// plan saved by an earlier version still loads after an update instead of
// being dropped.

extension SessionPlan {
    enum CodingKeys: String, CodingKey {
        case goal, duration, mode, apps, websites, reopensQuitApps, launchApps, startShortcut, endShortcut, strict
        case setupID, projectID, projectName, breakLength, breakRules, websiteExceptions, resources
        case isContinuation, sequenceStep
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
        // 0.4's fields, each on its own: one written wrongly is dropped, and
        // the session keeps its blocking rules.
        setupID = c.decodeTolerant(UUID.self, forKey: .setupID)
        projectID = c.decodeTolerant(UUID.self, forKey: .projectID)
        projectName = c.decodeTolerant(String.self, forKey: .projectName)
        breakLength = c.decodeTolerant(TimeInterval.self, forKey: .breakLength).map { max(0, $0) }
        breakRules = c.decodeTolerant(BreakRules.self, forKey: .breakRules)
        websiteExceptions = c.decodeLossy([WebsiteException].self, forKey: .websiteExceptions)
        resources = c.decodeLossy([WorkspaceResource].self, forKey: .resources)
        isContinuation = c.decodeTolerant(Bool.self, forKey: .isContinuation) ?? false
        sequenceStep = c.decodeTolerant(SequenceStepRef.self, forKey: .sequenceStep)
    }
}

extension BreakState {
    enum CodingKeys: String, CodingKey { case plan, endsAt, length, rules }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(SessionPlan.self, forKey: .plan)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        length = try c.decode(TimeInterval.self, forKey: .length)
        rules = c.decodeTolerant(BreakRules.self, forKey: .rules)
    }
}

extension SessionRecord {
    enum CodingKeys: String, CodingKey { case session, lastPlan, pendingBreak, sequence }

    /// Each part on its own: a break or sequence that doesn't decode is
    /// dropped, and the session that was running still resumes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = c.decodeTolerant(SessionState.self, forKey: .session)
        lastPlan = c.decodeTolerant(SessionPlan.self, forKey: .lastPlan)
        pendingBreak = c.decodeTolerant(BreakState.self, forKey: .pendingBreak)
        sequence = c.decodeTolerant(SequenceRun.self, forKey: .sequence)
    }
}

extension SessionState {
    enum CodingKeys: String, CodingKey {
        case plan, startedAt, phase, budget, snoozes, quitApps, blocks, quitCounts, foreground, activity, activitySegments, activityTimelineTruncated, activityContinuity, activityContinuityStartedAt, names
        case seenElapsed, endedAt, focusedTime, pausedAt, pauseReminded
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
        activity = c.decodeTolerant([FocusActivity].self, forKey: .activity)
        activitySegments = c.decodeTolerant([FocusActivitySegment].self, forKey: .activitySegments)
        activityTimelineTruncated = c.decodeTolerant(Bool.self, forKey: .activityTimelineTruncated)
        activityContinuity = c.decodeTolerant(Int.self, forKey: .activityContinuity) ?? 0
        activityContinuityStartedAt = c.decodeTolerant(Date.self, forKey: .activityContinuityStartedAt)
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        seenElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .seenElapsed) ?? 0
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        focusedTime = try c.decodeIfPresent(TimeInterval.self, forKey: .focusedTime)
        pausedAt = c.decodeTolerant(Date.self, forKey: .pausedAt)
        pauseReminded = c.decodeTolerant(Bool.self, forKey: .pauseReminded) ?? false
    }
}
