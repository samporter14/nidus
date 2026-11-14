//
//  ActivityRecorder.swift
//  Nidus
//
//  All-day activity: what was in front, stretch by stretch, whether or not a
//  focus session is on. It answers events (an app comes forward, the screen
//  locks, the Mac sleeps) and otherwise sets one timer for the next moment
//  anything could change, so an unchanging afternoon costs almost nothing.
//  The only regular work is the tab or window-title read, at most every four
//  seconds while someone is typing or clicking, and only every twenty while
//  they are not (and not at all while nothing has been touched since the
//  last read).
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
    /// While nobody has touched anything, the read is not repeated, and the
    /// recorder only looks every this often for input to start it again.
    nonisolated static let quietProbeInterval: TimeInterval = 20
    /// How soon a return from idle is noticed. There is no event for it
    /// without watching every input, which this will not do. Only the noticing
    /// is late: a stretch is back-dated to the last input, not to the poll.
    /// An app switch or a wake from sleep still reconciles at once.
    nonisolated static let idlePollInterval: TimeInterval = 30
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
    /// Whether today's record is failing to reach the disk changed.
    var onSaveTrouble: (Bool) -> Void = { _ in }
    /// Today's record isn't on disk: the last write of it failed, or its file
    /// could not be read. What's in memory stays unsaved and is tried again.
    private(set) var savesFailing = false {
        didSet { if savesFailing != oldValue { onSaveTrouble(savesFailing) } }
    }
    /// Today's file was there but could not be read. Until it can be, it is
    /// not written over; once it can, this run's time is added to it.
    private var todayUnreadable = false

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
    /// Only this run's observations may be retracted when idle is confirmed.
    private var dayContinuityFloor = 0
    /// Days crossed since the last input; normally at most yesterday. No
    /// history scan is needed when an idle spell straddles midnight.
    private var recentDays: [String: (floor: Int, end: Date)] = [:]
    private var hasSavedSnapshot = false
    private var savedOpenID: String?

    private var probeInFlight = false
    private var generation = 0
    private var lastProbeAt: Date?
    /// When the last read was either made or judged unnecessary. Only this
    /// moves while quiet, so the wake spacing doesn't depend on a read.
    private var lastProbeCheck: Date?
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
        store.onOutcome = { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.writeFinished(outcome) }
            }
        }
    }

    /// A write's result. One that failed leaves today unsaved, so the next
    /// periodic save writes the latest state again; nothing older is queued,
    /// so a clear in between is never undone.
    private func writeFinished(_ outcome: ActivityDayStore.Outcome) {
        guard let day = outcome.day, day == log.day else { return }
        if outcome.succeeded {
            if !todayUnreadable { savesFailing = false }
        } else {
            savesFailing = true
            if hasSavedSnapshot { hasUnsaved = true }
        }
    }

    // MARK: Reading

    /// On, and not paused: time is being counted when someone is here.
    var isRecording: Bool { isStarted && settings.enabled && !isPaused(at: clock()) }

    func isPaused(at date: Date) -> Bool { settings.pausedUntil.map { $0 > date } ?? false }

    /// Today so far, the open stretch included up to now.
    func today() -> ActivityDayLog {
        let t = clock()
        var snapshot = log
        let end = creditedEnd(at: t)
        if end < t, !isIdle { snapshot.trim(after: end, continuityAtLeast: dayContinuityFloor) }
        if let open, let segment = closing(open, at: end) {
            snapshot.add(segment)
        }
        return snapshot
    }

    /// The latest read, for a running session to share rather than ask again.
    func detail(forApp id: String, pid: pid_t) -> ActivityDetail? {
        guard let lastDetail, lastDetail.id == id, lastDetail.pid == pid,
              (0..<Self.detailLifetime).contains(clock().timeIntervalSince(lastDetail.at)) else { return nil }
        return lastDetail.detail
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastSeen = clock()
        idleFloor = lastSeen
        isIdle = false
        recentDays.removeAll()
        lastSavedAt = nil
        loadToday()
        prune()
        reconcile()
    }

    func stop() {
        guard isStarted else { return }
        let t = clock()
        correctIdle(at: t)
        roll(to: t)
        closeOpen(at: creditedEnd(at: t), at: t)
        save(at: t)
        isStarted = false
        invalidateReads()
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
                closeOpen(at: creditedEnd(at: t), at: t)
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
                idleFloor = clock()
                recentDays.removeAll()
                loadToday()
            } else {
                // Off means off now: the stretch in progress goes, and what
                // was already kept is written without it.
                if savedOpenID != nil { hasUnsaved = true }
                open = nil
                isIdle = false
                gap()
                if hasUnsaved { save(at: clock()) }
                idleFloor = clock()
                recentDays.removeAll()
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
        hasSavedSnapshot = false
        todayUnreadable = false
        savesFailing = false
        savedOpenID = nil
        recentDays.removeAll()
        idleFloor = clock()
        invalidateReads()
        gap()
        store.enqueue(.clear)
        onSave()
        reconcile()
    }

    /// Remove saved names: out of every day file and out of today in memory.
    func removeTitles() {
        dayContinuityFloor = redact(&log, preservingFloor: dayContinuityFloor)
        // Redaction inserts continuity boundaries to preserve former title
        // switches. Keep the current run above those rebased loaded rows.
        continuity = max(continuity, (log.stretches.map(\.continuity).max() ?? -1) + 1)
        open?.segment.continuity = continuity
        open?.segment.title = nil
        open?.segment.url = nil
        for (day, recent) in recentDays {
            guard var previous = store.load(day: day) else { continue }
            let floor = redact(&previous, preservingFloor: recent.floor)
            recentDays[day] = (floor, recent.end)
        }
        invalidateReads()
        store.enqueue(.removeTitles)
        onSave()
        reconcile()
    }

    private func redact(_ day: inout ActivityDayLog, preservingFloor floor: Int) -> Int {
        let owned = Set(day.stretches.lazy.filter { $0.continuity >= floor }.map(\.id))
        day.removeTitles()
        return day.stretches.lazy.filter { owned.contains($0.id) }.map(\.continuity).min()
            ?? ((day.stretches.map(\.continuity).max() ?? -1) + 1)
    }

    // MARK: Events

    func frontAppDidChange() {
        invalidateReads()
        reconcile()
    }

    func systemWillSleep() { isAsleep = true; suspend() }
    func systemDidWake() { isAsleep = false; resume() }
    func screenDidLock() { isLocked = true; suspend() }
    func screenDidUnlock() { isLocked = false; resume() }

    private func suspend() {
        invalidateReads()
        reconcile()
        idleFloor = clock()
        recentDays.removeAll()
    }

    private func resume() {
        invalidateReads()
        idleFloor = clock()
        reconcile()
    }

    /// Set the clock back and every open stretch would end before it began.
    func clockDidChange() {
        let t = clock()
        closeOpen(at: lastSeen, at: lastSeen)
        if hasUnsaved { save(at: lastSeen) }
        lastSeen = t
        gap()
        idleFloor = t
        dayContinuityFloor = continuity
        recentDays.removeAll()
        lastSavedAt = t
        reconcile()
    }

    /// A running session: silence counts as reading until it stops running.
    func setFocusRunning(_ running: Bool) {
        guard running != focusRunning else { return }
        // Settle the ordinary idle rule before a session begins counting
        // silence, and never use its old last-input date as the new start.
        if running, isStarted { reconcile(); isIdle = false }
        focusRunning = running
        if isStarted { idleFloor = clock() }
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
        correctIdle(at: t)
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
            if hasUnsaved { save(at: t) }
            if isPaused(at: t) {
                idleFloor = t
                recentDays.removeAll()
            }
            isIdle = false
            return
        }
        let since = idleSeconds
        if !focusRunning, since >= settings.idleCutoff {
            closeOpen(at: creditedEnd(at: t), at: t)
            if hasUnsaved { save(at: t) }
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
        return min(t, max(t.addingTimeInterval(-since), idleFloor ?? .distantPast))
    }

    /// A periodic snapshot and a context change may both predate the idle
    /// cutoff. Retract that provisional tail as soon as absence is known.
    private func correctIdle(at t: Date) {
        if focusRunning { recentDays.removeAll(); return }
        // Once absence has been settled there is no new tail to scan on
        // each ten-second poll, including when a late probe comes back.
        if isIdle, open == nil, recentDays.isEmpty { return }
        let input = max(t.addingTimeInterval(-idleSeconds), idleFloor ?? .distantPast)
        recentDays = recentDays.filter { $0.value.end > input }
        guard idleSeconds >= settings.idleCutoff else { return }
        let end = min(t, input)
        if log.trim(after: end, continuityAtLeast: dayContinuityFloor) { hasUnsaved = true }
        for (day, recent) in recentDays {
            // Retention may already have removed a day. Never recreate it.
            guard var previous = store.load(day: day),
                  previous.trim(after: end, continuityAtLeast: recent.floor) else { continue }
            store.enqueue(.write(previous))
            onSave()
        }
        recentDays.removeAll()
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
        if savedOpenID == closed.segment.id { hasUnsaved = true }
        if !continues { gap() }
        guard let segment = closing(closed, at: min(end, t)) else { return }
        file(segment)
    }

    private func gap() { continuity += 1; invalidateReads() }

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
        let file = store.loadFile(day: key)
        let loaded = file.log
        log = loaded ?? ActivityDayLog(day: key)
        // A corrupt file is set aside by the store at the first write.
        todayUnreadable = file == .inaccessible
        savesFailing = todayUnreadable
        continuity = max(continuity, (log.stretches.map(\.continuity).max() ?? -1) + 1)
        dayContinuityFloor = continuity
        hasSavedSnapshot = loaded != nil
        savedOpenID = nil
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
        if let end = log.stretches.map(\.end).max() {
            recentDays[log.day] = (dayContinuityFloor, end)
        }
        loadToday()
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
        if todayUnreadable {
            switch store.loadFile(day: log.day) {
            case .inaccessible:
                // Still can't be read: keep everything for the next try.
                hasUnsaved = true
                savesFailing = true
                return
            case .loaded(let onDisk):
                // Readable again: what was there comes first, then this run.
                var merged = onDisk
                for stretch in log.stretches { merged.add(stretch) }
                log = merged
                snapshot = log
                if let open, let segment = closing(open, at: creditedEnd(at: t)) { snapshot.add(segment) }
                hasSavedSnapshot = true
            case .absent, .corrupt:
                break
            }
            todayUnreadable = false
        }
        hasUnsaved = false
        // An empty correction must replace a nonempty periodic snapshot.
        // An untouched/off recorder still never creates a file.
        guard !snapshot.isEmpty || hasSavedSnapshot else { return }
        hasSavedSnapshot = true
        savedOpenID = open?.segment.id
        store.enqueue(.write(snapshot))
        onSave()
    }

    // MARK: Reading the front window

    private func invalidateReads() {
        generation &+= 1
        lastProbeAt = nil
        lastProbeCheck = nil
        lastDetail = nil
        failedProbes = 0
    }

    private func probeIfDue(_ front: ActivityFrontApp, at t: Date) {
        guard ActivityProbe.needsProbe(front.id, titles: settings.titles) else { return }
        guard !probeInFlight else { return }
        if let lastProbeAt, t.timeIntervalSince(lastProbeAt) >= Self.probeInterval { lastProbeCheck = t }
        guard Self.shouldProbe(lastProbeAt: lastProbeAt, now: t, secondsSinceInput: idleSeconds,
                               awaitingFirstRead: open?.awaitingFirstRead ?? true) else { return }
        probeInFlight = true
        lastProbeCheck = t
        lastProbeAt = t
        let asked = generation
        let titles = settings.titles
        host.probe(front, titles: titles) { [weak self] detail in
            self?.finishProbe(detail, for: front, asked: asked, at: t, titles: titles)
        }
    }

    /// Whether a read is worth making. Nothing read can have changed if there
    /// was no input since the last one (a streaming page's title may be
    /// noticed late, on purpose). The first read of a stretch always happens.
    nonisolated static func shouldProbe(lastProbeAt: Date?, now: Date, secondsSinceInput: TimeInterval,
                                        awaitingFirstRead: Bool) -> Bool {
        guard let lastProbeAt else { return true }
        let elapsed = now.timeIntervalSince(lastProbeAt)
        guard elapsed >= probeInterval else { return false }
        return awaitingFirstRead || secondsSinceInput <= elapsed
    }

    /// How long to wait before the next look: the usual spacing while there is
    /// input, the long one once a whole interval has passed with none.
    nonisolated static func probeSpacing(secondsSinceInput: TimeInterval) -> TimeInterval {
        secondsSinceInput >= probeInterval ? quietProbeInterval : probeInterval
    }

    private func finishProbe(_ detail: ActivityDetail?, for app: ActivityFrontApp, asked: Int, at requested: Date, titles: Bool) {
        // A result can arrive at midnight or just after the idle cutoff even
        // when no timer has run. Reconcile before it can close a stretch.
        // Keep the in-flight flag until then to avoid overlapping requests.
        if isStarted { reconcile() }
        probeInFlight = false
        guard isStarted else { return }
        // Things moved on while it was out: it describes nothing now, and a
        // cleared or opted-out name must not come back through it.
        guard asked == generation, settings.enabled, titles == settings.titles,
              !isLocked, !isAsleep, !isIdle,
              !settings.excluded.contains(app.id), !isPaused(at: clock()),
              let front = host.frontApp(), front.id == app.id, front.pid == app.pid else {
            reconcile()
            return
        }
        let t = clock()
        // A slow result cannot become fresh on arrival. Count it as a failed
        // read so repeated timeouts also retire the old site's attribution.
        if let detail, (0..<Self.detailLifetime).contains(t.timeIntervalSince(requested)) {
            lastDetail = (detail, app.id, app.pid, requested)
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
        } else if current.segment.url != nil, detail.url != nil,
                  !ActivityTimeline.samePage(current.segment.url, detail.url) {
            change(to: site, title: title, url: detail.url, at: t)
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
            if open != nil, !probeInFlight, let front = host.frontApp(),
               ActivityProbe.needsProbe(front.id, titles: settings.titles) {
                let spacing = Self.probeSpacing(secondsSinceInput: idleSeconds)
                let due = lastProbeAt.map { _ in spacing - t.timeIntervalSince(lastProbeCheck ?? t) } ?? 0
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

    private var fire: (@MainActor () -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        // The display coming back is the likeliest moment for the person to
        // return, and the idle poll is slow now: look straight away.
        // The host lives as long as the app, so the observer is never removed.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.timer != nil { self?.fire?() } }
        }
    }

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
        self.fire = seconds == nil ? nil : fire
        guard let seconds else { return }
        let next = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        // Let macOS bundle this with other wake-ups. Every wake re-reads the
        // clock and the last input, so a late one shifts nothing recorded.
        next.tolerance = min(5, seconds * 0.25)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
