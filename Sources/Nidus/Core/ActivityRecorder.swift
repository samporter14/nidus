//
//  ActivityRecorder.swift
//  Nidus
//
//  All-day activity: what was in front, stretch by stretch, whether or not a
//  focus session is on. It answers events (an app comes forward, the screen
//  locks, the Mac sleeps) and otherwise sets one timer for the next moment
//  anything could change, so an unchanging afternoon costs almost nothing.
//  The only regular work is the tab or window-title read, at most every four
//  seconds.
//
//  A stretch ends when the app, site or title changes, or at idle, lock,
//  sleep, a pause or midnight. Time after the last input is not credited,
//  except during a running focus session, where reading in silence counts.
//
//  Everything from the Mac comes through `ActivityRecorderHost`, so the tests
//  run on a fake clock and fake front apps.
//

import AppKit
import CoreGraphics

struct ActivityFrontApp: Equatable, Sendable {
    var id: String
    var name: String
    var pid: pid_t
    /// Has a Dock presence. Menu bar agents and panels don't count as work.
    var isRegular = true
}

@MainActor
protocol ActivityRecorderHost: AnyObject {
    func frontApp() -> ActivityFrontApp?
    func secondsSinceInput() -> TimeInterval
    /// Reads the tab or window title off the main actor and comes back on it.
    func probe(_ app: ActivityFrontApp, titles: Bool, completion: @escaping @MainActor (ActivityDetail?) -> Void)
    /// Replaces the one pending wake-up. nil cancels it.
    func arm(after seconds: TimeInterval?, fire: @escaping @MainActor () -> Void)
}

struct ActivityRecorderSettings: Equatable, Sendable {
    /// History, Activity and Track all day are all on, and this isn't a demo.
    var enabled = false
    var titles = false
    var excluded: Set<String> = []
    var idleCutoff: TimeInterval = ActivityRecorder.defaultIdleCutoff
    /// 0 keeps every day.
    var retentionDays = ActivityRecorder.defaultRetentionDays
    var pausedUntil: Date?
}

@MainActor
final class ActivityRecorder {
    nonisolated static let defaultIdleCutoff: TimeInterval = 5 * 60
    nonisolated static let defaultRetentionDays = 90
    /// Between reads of the front tab or title.
    nonisolated static let probeInterval: TimeInterval = 4
    /// How soon a return from idle is noticed. There is no event for it
    /// without watching every input, which this will not do.
    nonisolated static let idlePollInterval: TimeInterval = 10
    /// A crash loses at most this much.
    nonisolated static let saveInterval: TimeInterval = 120
    /// Passing through an app on the way to another isn't time in it.
    nonisolated static let shortestStretch: TimeInterval = 1
    /// A detail older than this no longer describes the front window.
    nonisolated static let detailLifetime: TimeInterval = 5
    /// Not worked in, though they can be frontmost.
    nonisolated static let notWork: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    private struct OpenStretch {
        var segment: FocusActivitySegment
        var pid: pid_t
        /// Still waiting for the first read of the tab or title.
        var awaitingFirstRead: Bool

        /// A browser's first read may yet say this is a private window, so
        /// until then none of it may be kept.
    }

    private let host: any ActivityRecorderHost
    private let clock: () -> Date
    private let calendar: Calendar
    let store: ActivityDayStore
    /// A save landed; a page showing the day can refresh.
    var onSave: () -> Void = {}

    private(set) var settings = ActivityRecorderSettings()
    private var isStarted = false
    private var isLocked = false
    private var isAsleep = false
    private var focusRunning = false
    /// While set, idle time before this is not cut: a session just stopped
    /// counting silence as work, and everything up to here was session time.
    private var idleFloor: Date?
    private(set) var isIdle = false

    private var log: ActivityDayLog
    private var open: OpenStretch?
    /// Bumped at every gap, so stretches either side of it never read as one.
    private var continuity = 0
    private var lastSavedAt: Date?
    private var hasUnsaved = false
    private var lastSeen: Date

    private var probeInFlight = false
    private var generation = 0
    private var lastProbeAt: Date?
    private var failedProbes = 0
    private var lastDetail: (detail: ActivityDetail, id: String, pid: pid_t, at: Date)?
    /// The private window in front, kept out until a read says otherwise.
    private var lastPruneDay: String?

    init(store: ActivityDayStore, host: any ActivityRecorderHost, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.store = store
        self.host = host
        clock = now
        self.calendar = calendar
        let today = now()
        log = ActivityDayLog(day: ActivityDayLog.key(for: today, calendar: calendar))
        lastSeen = today
    }

    // MARK: Reading

    /// On, and not paused: time is being counted when someone is here.
    var isRecording: Bool { isStarted && settings.enabled && !isPaused(at: clock()) }

    func isPaused(at date: Date) -> Bool { settings.pausedUntil.map { $0 > date } ?? false }

    /// Today so far, the open stretch included up to now.
    func today() -> ActivityDayLog {
        let t = clock()
        var snapshot = log
        if let open, let segment = closing(open, at: creditedEnd(at: t)) {
            snapshot.add(segment)
        }
        return snapshot
    }

    /// The latest read, for a running session to share rather than ask again.
    func detail(forApp id: String, pid: pid_t) -> ActivityDetail? {
        guard let lastDetail, lastDetail.id == id, lastDetail.pid == pid,
              clock().timeIntervalSince(lastDetail.at) < Self.detailLifetime else { return nil }
        return lastDetail.detail
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastSeen = clock()
        loadToday()
        prune()
        reconcile()
    }

    func stop() {
        guard isStarted else { return }
        let t = clock()
        closeOpen(at: creditedEnd(at: t), at: t)
        save(at: t)
        isStarted = false
        generation &+= 1
        host.arm(after: nil) {}
        store.flush()
    }

    func apply(_ new: ActivityRecorderSettings) {
        let old = settings
        guard old != new else { return }
        settings = new
        guard isStarted else { return }
        if old.retentionDays != new.retentionDays { lastPruneDay = nil; prune() }
        let added = new.excluded.subtracting(old.excluded)
        if !added.isEmpty {
            // Saved time stays, hidden by the views, and comes back if the
            // app is let in again.
            invalidateReads()
            if let open, added.contains(open.segment.appID) {
                let t = clock()
                closeOpen(at: t, at: t)
            }
            onSave()
        }
        if old.titles != new.titles {
            invalidateReads()
            if !new.titles { open?.segment.title = nil }
        }
        if old.enabled != new.enabled {
            invalidateReads()
            if new.enabled {
                loadToday()
            } else {
                // Off means off now: the stretch in progress goes, and what
                // was already kept is written without it.
                open = nil
                isIdle = false
                gap()
                if hasUnsaved { save(at: clock()) }
            }
        }
        reconcile()
    }

    /// Clear history: every day file goes, and nothing in progress survives
    /// to bring any of it back.
    func clear() {
        log = ActivityDayLog(day: log.day)
        open = nil
        hasUnsaved = false
        invalidateReads()
        gap()
        store.enqueue(.clear)
        onSave()
        reconcile()
    }

    /// Remove saved names: out of every day file and out of today in memory.
    func removeTitles() {
        log.removeTitles()
        open?.segment.title = nil
        invalidateReads()
        store.enqueue(.removeTitles)
        onSave()
        reconcile()
    }

    // MARK: Events

    func frontAppDidChange() {
        invalidateReads()
        reconcile()
    }

    func systemWillSleep() { isAsleep = true; reconcile() }
    func systemDidWake() { isAsleep = false; reconcile() }
    func screenDidLock() { isLocked = true; reconcile() }
    func screenDidUnlock() { isLocked = false; reconcile() }

    /// Set the clock back and every open stretch would end before it began.
    func clockDidChange() {
        let t = clock()
        closeOpen(at: lastSeen, at: lastSeen)
        lastSeen = t
        gap()
        reconcile()
    }

    /// A running session: silence counts as reading until it stops running.
    func setFocusRunning(_ running: Bool) {
        guard running != focusRunning else { return }
        focusRunning = running
        if isStarted { idleFloor = running ? nil : clock() }
        reconcile()
    }

    // MARK: The one decision

    /// Brings the record in line with the Mac right now, then sets the next
    /// wake-up. Every event and every timer ends up here.
    private func reconcile() {
        guard isStarted else { return }
        guard settings.enabled else {
            host.arm(after: nil) {}
            return
        }
        let t = clock()
        lastSeen = t
        roll(to: t)
        observe(at: t)
        if let lastSavedAt, hasPending, t.timeIntervalSince(lastSavedAt) >= Self.saveInterval {
            save(at: t)
        } else if lastSavedAt == nil, hasPending {
            lastSavedAt = t
        }
        scheduleWake(at: t)
    }

    private var hasPending: Bool { hasUnsaved || open != nil }

    private func observe(at t: Date) {
        guard !isLocked, !isAsleep, !isPaused(at: t) else {
            closeOpen(at: creditedEnd(at: t), at: t)
            isIdle = false
            return
        }
        let since = idleSeconds
        if !focusRunning, since >= settings.idleCutoff {
            closeOpen(at: creditedEnd(at: t), at: t)
            isIdle = true
            return
        }
        let returning = isIdle
        isIdle = false
        guard let front = host.frontApp(), isRecordable(front) else {
            closeOpen(at: t, at: t)
            return
        }
        if let open, open.segment.appID != front.id || open.pid != front.pid {
            closeOpen(at: t, at: t, continues: true)
        }
        if open == nil {
            let start = returning ? max(t.addingTimeInterval(-since), idleFloor ?? .distantPast) : t
            open = OpenStretch(segment: FocusActivitySegment(start: start, end: t, appID: front.id, appName: front.name,
                                                             continuity: continuity),
                               pid: front.pid,
                               awaitingFirstRead: ActivityProbe.needsProbe(front.id, titles: settings.titles))
            failedProbes = 0
        }
        probeIfDue(front, at: t)
    }

    private var idleSeconds: TimeInterval { max(0, host.secondsSinceInput()) }

    private func isRecordable(_ app: ActivityFrontApp) -> Bool {
        app.isRegular && !Self.notWork.contains(app.id) && !settings.excluded.contains(app.id)
    }

    /// Where credit ends if counting stopped now: now, unless the person had
    /// already gone. A session's silence counts, up to when the session stopped.
    private func creditedEnd(at t: Date) -> Date {
        guard !focusRunning else { return t }
        let since = idleSeconds
        guard since >= settings.idleCutoff else { return t }
        return max(t.addingTimeInterval(-since), idleFloor ?? .distantPast)
    }

    private func closing(_ open: OpenStretch, at end: Date) -> FocusActivitySegment? {
        var segment = open.segment
        segment.end = end
        guard segment.seconds >= Self.shortestStretch else { return nil }
        return segment
    }

    /// `end` is where credit stops; `t` is when that was decided. `continues`
    /// is a change of context with no time missing between the two.
    private func closeOpen(at end: Date, at t: Date, continues: Bool = false) {
        guard let closed = open else { return }
        open = nil
        if !continues { gap() }
        guard let segment = closing(closed, at: min(end, t)) else { return }
        file(segment)
    }

    private func gap() { continuity += 1 }

    private func file(_ segment: FocusActivitySegment) {
        for (day, piece) in ActivityDayLog.split(segment, calendar: calendar) {
            if day == log.day {
                log.add(piece)
                hasUnsaved = true
            } else {
                var other = store.load(day: day) ?? ActivityDayLog(day: day)
                other.add(piece)
                store.enqueue(.write(other))
            }
        }
    }

    // MARK: Days

    private func loadToday() {
        guard settings.enabled else { return }
        let key = ActivityDayLog.key(for: clock(), calendar: calendar)
        log = store.load(day: key) ?? ActivityDayLog(day: key)
        continuity = (log.stretches.map(\.continuity).max() ?? -1) + 1
        hasUnsaved = false
    }

    /// Crossing midnight ends the day's file: the stretch in progress is cut
    /// there and goes on in the next day's, and old days are let go.
    private func roll(to t: Date) {
        let key = ActivityDayLog.key(for: t, calendar: calendar)
        guard key != log.day else { return }
        let midnight = calendar.startOfDay(for: t)
        var carried = open
        if open != nil {
            let credited = creditedEnd(at: t)
            closeOpen(at: min(midnight, credited), at: t, continues: true)
            if credited <= midnight { carried = nil }
        }
        if hasUnsaved { save(at: t) }
        log = store.load(day: key) ?? ActivityDayLog(day: key)
        if var carried {
            carried.segment.id = UUID().uuidString
            carried.segment.start = midnight
            carried.segment.continuity = continuity
            open = carried
        }
        prune()
    }

    private func prune() {
        let today = ActivityDayLog.key(for: clock(), calendar: calendar)
        guard lastPruneDay != today else { return }
        lastPruneDay = today
        guard let first = ActivityDayLog.retentionStart(days: settings.retentionDays, today: clock(), calendar: calendar) else { return }
        store.enqueue(.prune(before: first))
    }

    private func save(at t: Date) {
        lastSavedAt = t
        var snapshot = log
        if let open, let segment = closing(open, at: creditedEnd(at: t)) {
            snapshot.add(segment)
        }
        hasUnsaved = false
        guard !snapshot.isEmpty else { return }
        store.enqueue(.write(snapshot))
        onSave()
    }

    // MARK: Reading the front window

    private func invalidateReads() {
        generation &+= 1
        lastProbeAt = nil
        lastDetail = nil
        failedProbes = 0
    }

    private func probeIfDue(_ front: ActivityFrontApp, at t: Date) {
        guard ActivityProbe.needsProbe(front.id, titles: settings.titles) else { return }
        guard !probeInFlight,
              lastProbeAt.map({ t.timeIntervalSince($0) >= Self.probeInterval }) ?? true else { return }
        probeInFlight = true
        lastProbeAt = t
        let asked = generation
        let titles = settings.titles
        host.probe(front, titles: titles) { [weak self] detail in
            self?.finishProbe(detail, for: front, asked: asked, titles: titles)
        }
    }

    private func finishProbe(_ detail: ActivityDetail?, for app: ActivityFrontApp, asked: Int, titles: Bool) {
        probeInFlight = false
        guard isStarted else { return }
        // Things moved on while it was out: it describes nothing now, and a
        // cleared or opted-out name must not come back through it.
        guard asked == generation, settings.enabled, titles == settings.titles,
              !settings.excluded.contains(app.id), !isPaused(at: clock()),
              let front = host.frontApp(), front.id == app.id, front.pid == app.pid else {
            reconcile()
            return
        }
        let t = clock()
        if let detail {
            lastDetail = (detail, app.id, app.pid, t)
            failedProbes = 0
            take(detail, for: app, at: t)
        } else {
            failedProbes += 1
            lastDetail = nil
            if open?.awaitingFirstRead == true {
                // App time, then: a browser that can't be read says nothing
                // about the page, and nothing about it is recorded.
                open?.awaitingFirstRead = false
            } else if failedProbes >= 2, open?.segment.site != nil || open?.segment.title != nil {
                // The page can't be read any more, so it can't be vouched for.
                change(to: nil, title: nil, at: t)
            }
        }
        scheduleWake(at: t)
    }

    private func take(_ detail: ActivityDetail, for app: ActivityFrontApp, at t: Date) {
        let site = ActivityTimeline.safeDaySite(detail.site ?? detail.domain)
        let title = settings.titles ? detail.title : nil
        guard let current = open else { return }
        open?.awaitingFirstRead = false
        if current.awaitingFirstRead {
            open?.segment.site = site
            open?.segment.title = title
            open?.segment.url = detail.url
        } else if current.segment.site == site, title == nil || current.segment.title == nil {
            // A name arriving late, or one read that returned none.
            open?.segment.title = title ?? current.segment.title
            open?.segment.url = detail.url ?? current.segment.url
        } else if current.segment.site != site || current.segment.title != title {
            change(to: site, title: title, url: detail.url, at: t)
        } else {
            open?.segment.url = detail.url ?? current.segment.url
        }
    }

    private func change(to site: String?, title: String?, url: String? = nil, at t: Date) {
        guard let current = open else { return }
        var next = current
        closeOpen(at: t, at: t, continues: true)
        next.segment = FocusActivitySegment(start: t, end: t, appID: current.segment.appID, appName: current.segment.appName,
                                            site: site, title: title, url: url, continuity: continuity)
        next.awaitingFirstRead = false
        open = next
    }

    // MARK: The next wake-up

    private func scheduleWake(at t: Date) {
        guard isStarted, settings.enabled, !isLocked, !isAsleep else {
            host.arm(after: nil) {}
            return
        }
        var wait = calendar.dateInterval(of: .day, for: t).map { $0.end.timeIntervalSince(t) } ?? 3600
        if isPaused(at: t), let pausedUntil = settings.pausedUntil {
            wait = min(wait, pausedUntil.timeIntervalSince(t))
        } else {
            if isIdle { wait = min(wait, Self.idlePollInterval) }
            if open != nil, !focusRunning { wait = min(wait, settings.idleCutoff - idleSeconds) }
            if open != nil, let front = host.frontApp(),
               ActivityProbe.needsProbe(front.id, titles: settings.titles) {
                let due = lastProbeAt.map { Self.probeInterval - t.timeIntervalSince($0) } ?? 0
                wait = min(wait, due)
            }
            if hasPending {
                let saved = lastSavedAt ?? t
                wait = min(wait, Self.saveInterval - t.timeIntervalSince(saved))
            }
        }
        host.arm(after: max(1, wait)) { [weak self] in self?.reconcile() }
    }
}

/// The Mac itself.
@MainActor
final class SystemActivityHost: ActivityRecorderHost {
    private let queue: DispatchQueue
    private var timer: Timer?

    init(queue: DispatchQueue) { self.queue = queue }

    func frontApp() -> ActivityFrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        return ActivityFrontApp(id: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                                isRegular: app.activationPolicy == .regular)
    }

    /// Any input, from anything in this login session. Needs no permission
    /// and tells nothing about what the input was.
    func secondsSinceInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func probe(_ app: ActivityFrontApp, titles: Bool, completion: @escaping @MainActor (ActivityDetail?) -> Void) {
        queue.async {
            let detail = ActivityProbe.detail(bundleID: app.id, pid: app.pid, titles: titles)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(detail) } }
        }
    }

    func arm(after seconds: TimeInterval?, fire: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = nil
        guard let seconds else { return }
        let next = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        // Let macOS bundle this with other wake-ups.
        next.tolerance = min(2, seconds * 0.25)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
